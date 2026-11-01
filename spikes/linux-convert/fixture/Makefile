hevcfix: hevcfix.c
	$(CC) -O2 -g -Wall -Wextra -o $@ $< $(shell pkg-config --cflags --libs libva libva-drm)

clean:
	rm -f hevcfix
