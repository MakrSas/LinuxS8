/*
 * fbbench — сколько стоит доставка кадра на экран без настоящего KMS.
 *
 * У нас нет драйвера дисплея, есть simpledrm поверх буфера, оставленного
 * загрузчиком. Переключения буферов там нет в принципе: на каждом коммите
 * ядро КОПИРУЕТ содержимое в память экрана процессором. Эта копия —
 * обязательный расход на каждый кадр, и она задаёт потолок частоты кадров
 * независимо от того, насколько быстр GPU.
 *
 * Меряем ровно её, без композитора и без GPU:
 *
 *   чтение   память экрана -> ОЗУ   (она несквозная, чтение из неё дорого)
 *   запись   ОЗУ -> память экрана   (это и делает simpledrm на каждый кадр)
 *
 * Хитрость: сначала считываем текущее содержимое экрана, а потом пишем
 * обратно ровно те же байты. Замер получается на настоящем объёме, но
 * картинка на экране не портится, так что опыт можно гонять при живой
 * оболочке.
 *
 * Сборка на телефоне:  cc -O2 -o fbbench fbbench.c
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/fb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	int reps = (argc > 1) ? atoi(argv[1]) : 20;
	const char *dev = (argc > 2) ? argv[2] : "/dev/fb0";

	int fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return 1;
	}

	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	if (ioctl(fd, FBIOGET_VSCREENINFO, &var) ||
	    ioctl(fd, FBIOGET_FSCREENINFO, &fix)) {
		perror("ioctl");
		return 1;
	}

	size_t frame = (size_t)fix.line_length * var.yres;
	double mb = frame / 1048576.0;

	printf("экран      : %ux%u, %u бит, строка %u байт\n",
	       var.xres, var.yres, var.bits_per_pixel, fix.line_length);
	printf("кадр       : %.2f МБ\n", mb);

	unsigned char *fb = mmap(NULL, frame, PROT_READ | PROT_WRITE,
				 MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	unsigned char *ram = malloc(frame);
	unsigned char *ram2 = malloc(frame);
	if (!ram || !ram2) {
		fprintf(stderr, "не хватило памяти на два кадра\n");
		return 1;
	}

	/* Сохраняем то, что сейчас на экране: писать будем именно это. */
	double t0 = now();
	memcpy(ram, fb, frame);
	double t_read = now() - t0;

	/* Опорная скорость: обычная память в обычную память. */
	memcpy(ram2, ram, frame);		/* прогрев */
	t0 = now();
	for (int i = 0; i < reps; i++)
		memcpy(ram2, ram, frame);
	double t_ram = (now() - t0) / reps;

	/* Главное: запись в память экрана. Содержимое не меняется. */
	memcpy(fb, ram, frame);			/* прогрев */
	t0 = now();
	for (int i = 0; i < reps; i++)
		memcpy(fb, ram, frame);
	double t_write = (now() - t0) / reps;

	printf("\n");
	printf("ОЗУ -> ОЗУ            : %7.2f мс  %7.0f МБ/с\n",
	       t_ram * 1e3, mb / t_ram);
	printf("экран -> ОЗУ (чтение) : %7.2f мс  %7.0f МБ/с\n",
	       t_read * 1e3, mb / t_read);
	printf("ОЗУ -> экран (запись) : %7.2f мс  %7.0f МБ/с\n",
	       t_write * 1e3, mb / t_write);

	printf("\nодна такая запись на кадр => потолок %.1f кадр/с\n",
	       1.0 / t_write);
	printf("(GPU рисует полноэкранный проход примерно за 0.43 мс,\n");
	printf(" так что если потолок низкий — узкое место здесь, а не в GPU)\n");

	munmap(fb, frame);
	close(fd);
	return 0;
}
