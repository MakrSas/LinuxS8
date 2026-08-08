/*
 * gputest — проверка, что GPU действительно СЧИТАЕТ, а не только опознан.
 *
 * Зачем свой: готовые бенчмарки (glmark2 и родня) все требуют дисплей —
 * X11, Wayland или KMS. У нас KMS-устройство это simpledrm, голый буфер
 * кадра от загрузчика, и через него Mesa уходит в программный растеризатор.
 * То есть любой такой бенчмарк померил бы процессор, а не Mali.
 *
 * Здесь дисплей не нужен вовсе: surfaceless EGL прямо на рендер-узле
 * panfrost, рисуем в FBO.
 *
 * Главное отличие от eglinfo: тот печатает строку GL_RENDERER, которую
 * драйвер собирает из таблицы моделей, и она ничего не доказывает про
 * работу. Здесь после рисования пиксели ЧИТАЮТСЯ обратно и сверяются с
 * ожидаемым цветом. Если GPU не считает, проверка не сойдётся, каким бы
 * ни был GL_RENDERER.
 *
 * Сборка:
 *   gcc -O2 -o gputest gputest.c -lEGL -lGLESv2 -lm
 */
#define _POSIX_C_SOURCE 199309L

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define W 512
#define H 512

static double now_sec(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void die(const char *what)
{
	fprintf(stderr, "!! %s (EGL 0x%04x, GL 0x%04x)\n", what,
		eglGetError(), glGetError());
	exit(1);
}

/*
 * Шейдер намеренно не тривиальный: несколько итераций с sin/cos, чтобы
 * нагрузка легла на шейдерные ядра, а не упёрлась в пропускную способность
 * памяти. Иначе тест мерил бы шину, а не GPU.
 */
static const char *vs_src =
	"attribute vec2 pos;\n"
	"varying vec2 uv;\n"
	"void main() {\n"
	"  uv = pos;\n"
	"  gl_Position = vec4(pos, 0.0, 1.0);\n"
	"}\n";

static const char *fs_src =
	"precision highp float;\n"
	"varying vec2 uv;\n"
	"uniform int iters;\n"
	"void main() {\n"
	"  float a = 0.0;\n"
	"  vec2 p = uv;\n"
	"  for (int i = 0; i < 64; i++) {\n"
	"    if (i >= iters) break;\n"
	"    a += sin(p.x * 3.0 + a) * cos(p.y * 3.0 - a);\n"
	"    p = p * 1.01;\n"
	"  }\n"
	"  /* Прижимаем к заведомо известному цвету: результат проверяемый. */\n"
	"  gl_FragColor = vec4(0.25 + 0.0001 * a, 0.5, 0.75, 1.0);\n"
	"}\n";

static GLuint compile(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);

	GLint ok = 0;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[2048] = {0};
		glGetShaderInfoLog(s, sizeof(log) - 1, NULL, log);
		fprintf(stderr, "!! шейдер не собрался:\n%s\n", log);
		exit(1);
	}
	return s;
}

int main(int argc, char **argv)
{
	int frames = (argc > 1) ? atoi(argv[1]) : 200;
	int iters = (argc > 2) ? atoi(argv[2]) : 64;

	/* ---- EGL без всякого дисплея ---- */
	EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (dpy == EGL_NO_DISPLAY)
		die("eglGetDisplay");

	EGLint major, minor;
	if (!eglInitialize(dpy, &major, &minor))
		die("eglInitialize");
	printf("EGL %d.%d, vendor: %s\n", major, minor,
	       eglQueryString(dpy, EGL_VENDOR));

	if (!eglBindAPI(EGL_OPENGL_ES_API))
		die("eglBindAPI");

	static const EGLint cfg_attr[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_NONE
	};
	EGLConfig cfg;
	EGLint n = 0;
	if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n) || n < 1)
		die("eglChooseConfig: подходящей конфигурации нет");

	static const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2,
					   EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
	if (ctx == EGL_NO_CONTEXT)
		die("eglCreateContext");

	/* Поверхность не нужна: рисуем в FBO. */
	if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
		die("eglMakeCurrent");

	printf("GL_VENDOR   : %s\n", glGetString(GL_VENDOR));
	printf("GL_RENDERER : %s\n", glGetString(GL_RENDERER));
	printf("GL_VERSION  : %s\n", glGetString(GL_VERSION));
	printf("GLSL        : %s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));

	/* ---- цель рисования ---- */
	GLuint tex, fbo;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA,
		     GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
			       GL_TEXTURE_2D, tex, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
		die("FBO неполон");

	/* ---- программа ---- */
	GLuint prog = glCreateProgram();
	glAttachShader(prog, compile(GL_VERTEX_SHADER, vs_src));
	glAttachShader(prog, compile(GL_FRAGMENT_SHADER, fs_src));
	glBindAttribLocation(prog, 0, "pos");
	glLinkProgram(prog);

	GLint ok = 0;
	glGetProgramiv(prog, GL_LINK_STATUS, &ok);
	if (!ok) {
		char log[2048] = {0};
		glGetProgramInfoLog(prog, sizeof(log) - 1, NULL, log);
		fprintf(stderr, "!! программа не слинковалась:\n%s\n", log);
		return 1;
	}
	glUseProgram(prog);
	glUniform1i(glGetUniformLocation(prog, "iters"), iters);

	static const GLfloat quad[] = { -1, -1,  1, -1, -1,  1,
					 1, -1,  1,  1, -1,  1 };
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);

	glViewport(0, 0, W, H);

	/* ---- прогрев: первый кадр включает компиляцию и выделения ---- */
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawArrays(GL_TRIANGLES, 0, 6);
	glFinish();

	/* ---- проверка правильности ---- */
	unsigned char px[4] = {0};
	glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	printf("\nпиксель в центре: R=%u G=%u B=%u A=%u (ждём ~64 128 191 255)\n",
	       px[0], px[1], px[2], px[3]);

	int sane = (abs((int)px[1] - 128) <= 2) && (abs((int)px[2] - 191) <= 2) &&
		   (px[3] == 255);
	printf("рисование %s\n",
	       sane ? "ПОДТВЕРЖДЕНО (пиксели совпали)"
		    : "НЕ ПОДТВЕРЖДЕНО (пиксели не те)");

	/* ---- замер ---- */
	double t0 = now_sec();
	for (int i = 0; i < frames; i++) {
		glClear(GL_COLOR_BUFFER_BIT);
		glDrawArrays(GL_TRIANGLES, 0, 6);
	}
	glFinish();
	double dt = now_sec() - t0;

	double mpix = (double)W * H * frames / 1e6;
	printf("\n%d кадров %dx%d, %d итераций в пикселе\n", frames, W, H, iters);
	printf("время      : %.3f с\n", dt);
	printf("кадров/с   : %.1f\n", frames / dt);
	printf("Мпикс/с    : %.1f\n", mpix / dt);

	GLenum err = glGetError();
	if (err != GL_NO_ERROR)
		printf("\n!! GL сообщил об ошибке 0x%04x\n", err);

	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglTerminate(dpy);
	return sane ? 0 : 2;
}
