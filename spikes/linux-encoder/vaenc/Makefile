vaenc: vaenc.c
	$(CC) -O2 -Wall -Wextra -o $@ $< $(shell pkg-config --cflags --libs libva libva-drm)

clean:
	rm -f vaenc
