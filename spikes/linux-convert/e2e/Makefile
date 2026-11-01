PKGS = egl gbm libva libva-drm libdrm libpipewire-0.3

e2e: e2e.c
	$(CC) -O2 -g -Wall -Wextra -o $@ $< $(shell pkg-config --cflags --libs $(PKGS))

clean:
	rm -f e2e
