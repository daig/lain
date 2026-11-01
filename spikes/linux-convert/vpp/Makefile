vpp: vpp.c
	$(CC) -O2 -Wall -Wextra -o $@ $< $(shell pkg-config --cflags --libs libva libva-drm gbm libdrm) -lm -lpthread

clean:
	rm -f vpp

.PHONY: clean
