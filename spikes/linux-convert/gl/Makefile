CFLAGS ?= -O2 -g -Wall -Wextra
PKGS = egl gbm libva libva-drm libdrm

glconv: glconv.c
	$(CC) $(CFLAGS) -o $@ $< $(shell pkg-config --cflags --libs $(PKGS)) -lm

clean:
	rm -f glconv
