// pwprobe: a PipeWire consumer for one Mutter screen-cast node, for spike B.
//
// Connects to the node, offers a raw video format with a fixed size and a maximum frame rate, asks for
// header, damage and cursor metadata, and prints one JSON object per line on stdout:
//   {"ev":"format",...}      the negotiated format (size, framerate, max framerate, video format, modifier)
//   {"ev":"frame",...}       a buffer with picture content (pts, seq, damage rects, arrival time)
//   {"ev":"cursor",...}      a change in the cursor metadata (id, position, hotspot, bitmap)
//   {"ev":"stats",...}       once a second: buffers, picture frames, cursor-only buffers
// Shared memory (MemFd/MemPtr) by default; with dmabuf=<modifier> it asks for DMA-BUFs with that one DRM
// modifier instead (and never maps them), to see whether the frame rate is bound by Mutter's copy to shm.
//
// Build: cc -O2 -o pwprobe pwprobe.c $(pkg-config --cflags --libs libpipewire-0.3)
// Usage: pwprobe <node-id> <width> <height> <max-fps> <seconds> [bitmaps] [dmabuf=<modifier>]
//   bitmaps: also dump each new cursor bitmap's checksum, its hotspot pixel and alpha statistics.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/buffers.h>
#include <spa/buffer/meta.h>
#include <spa/debug/types.h>
#include <spa/param/video/type-info.h>

#define CURSOR_META_SIZE(w, h) \
	(sizeof(struct spa_meta_cursor) + sizeof(struct spa_meta_bitmap) + (w) * (h) * 4)

struct probe {
	struct pw_main_loop *loop;
	struct pw_stream *stream;
	struct spa_hook listener;
	struct spa_video_info_raw info;
	int dump_bitmaps;
	int dmabuf;
	uint64_t modifier;
	uint64_t buffers, pictures, cursor_only, empty;
	uint64_t window_buffers, window_pictures;
	uint32_t last_cursor_id;
	int32_t last_x, last_y;
	int have_cursor;
	int seen_cursor_meta;
	double last_picture_s;
	double max_gap_s;
};

static double now_s(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
	struct probe *p = data;
	if (param == NULL || id != SPA_PARAM_Format)
		return;
	uint32_t media_type, media_subtype;
	if (spa_format_parse(param, &media_type, &media_subtype) < 0)
		return;
	spa_format_video_raw_parse(param, &p->info);
	printf("{\"ev\":\"format\",\"t\":%.6f,\"format\":\"%s\",\"width\":%u,\"height\":%u,"
	       "\"framerate\":\"%u/%u\",\"max_framerate\":\"%u/%u\",\"modifier\":%llu}\n",
	       now_s(), spa_debug_type_find_short_name(spa_type_video_format, p->info.format), p->info.size.width,
	       p->info.size.height, p->info.framerate.num, p->info.framerate.denom, p->info.max_framerate.num,
	       p->info.max_framerate.denom, (unsigned long long)p->info.modifier);
	fflush(stdout);

	uint8_t buffer[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	const struct spa_pod *params[4];
	params[0] = spa_pod_builder_add_object(
		&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers, SPA_PARAM_BUFFERS_buffers,
		SPA_POD_CHOICE_RANGE_Int(4, 2, 8), SPA_PARAM_BUFFERS_dataType,
		SPA_POD_CHOICE_FLAGS_Int(p->dmabuf ? (1 << SPA_DATA_DmaBuf)
					       : ((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr))));
	params[1] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type,
					       SPA_POD_Id(SPA_META_Header), SPA_PARAM_META_size,
					       SPA_POD_Int(sizeof(struct spa_meta_header)));
	params[2] = spa_pod_builder_add_object(
		&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Cursor),
		SPA_PARAM_META_size,
		SPA_POD_CHOICE_RANGE_Int(CURSOR_META_SIZE(384, 384), CURSOR_META_SIZE(1, 1), CURSOR_META_SIZE(384, 384)));
	params[3] = spa_pod_builder_add_object(
		&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_VideoDamage),
		SPA_PARAM_META_size,
		SPA_POD_CHOICE_RANGE_Int(sizeof(struct spa_meta_region) * 16, sizeof(struct spa_meta_region) * 1,
					 sizeof(struct spa_meta_region) * 16));
	pw_stream_update_params(p->stream, params, 4);
}

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
	(void)old;
	printf("{\"ev\":\"state\",\"t\":%.6f,\"state\":\"%s\",\"error\":\"%s\"}\n", now_s(),
	       pw_stream_state_as_string(state), error ? error : "");
	fflush(stdout);
}

static void on_process(void *data) {
	struct probe *p = data;
	struct pw_buffer *b;
	struct pw_buffer *last = NULL;
	while ((b = pw_stream_dequeue_buffer(p->stream)) != NULL) {
		struct spa_buffer *buf = b->buffer;
		double t = now_s();
		p->buffers++;
		p->window_buffers++;

		struct spa_meta_header *h = spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof(*h));
		struct spa_chunk *chunk = buf->datas[0].chunk;
		if (p->buffers == 1)
			printf("{\"ev\":\"buffer_type\",\"type\":\"%s\",\"planes\":%u}\n",
			       spa_debug_type_find_short_name(spa_type_data_type, buf->datas[0].type), buf->n_datas);
		int has_picture = chunk->size > 0 && !(chunk->flags & SPA_CHUNK_FLAG_CORRUPTED);
		if (chunk->size == 0)
			p->empty++;

		struct spa_meta_cursor *c = spa_buffer_find_meta_data(buf, SPA_META_Cursor, sizeof(*c));
		if (c) {
			int valid = spa_meta_cursor_is_valid(c);
			if (!valid && (p->have_cursor || !p->seen_cursor_meta)) {
				p->seen_cursor_meta = 1;
				printf("{\"ev\":\"cursor\",\"t\":%.6f,\"valid\":false}\n", t);
				p->have_cursor = 0;
			} else if (valid && (!p->have_cursor || c->id != p->last_cursor_id ||
					     c->position.x != p->last_x || c->position.y != p->last_y ||
					     c->bitmap_offset)) {
				printf("{\"ev\":\"cursor\",\"t\":%.6f,\"valid\":true,\"id\":%u,\"x\":%d,\"y\":%d,"
				       "\"hot_x\":%d,\"hot_y\":%d,\"flags\":%u",
				       t, c->id, c->position.x, c->position.y, c->hotspot.x, c->hotspot.y, c->flags);
				if (c->bitmap_offset >= sizeof(*c)) {
					struct spa_meta_bitmap *bm = SPA_PTROFF(c, c->bitmap_offset, struct spa_meta_bitmap);
					printf(",\"bitmap\":{\"format\":\"%s\",\"w\":%u,\"h\":%u,\"stride\":%d}",
					       spa_debug_type_find_short_name(spa_type_video_format, bm->format), bm->size.width,
					       bm->size.height, bm->stride);
					if (p->dump_bitmaps && bm->size.width > 0 && bm->offset >= sizeof(*bm)) {
						const uint8_t *px = SPA_PTROFF(bm, bm->offset, const uint8_t);
						uint32_t sum = 0;
						for (uint32_t y = 0; y < bm->size.height; y++)
							for (uint32_t x = 0; x < bm->size.width * 4; x++)
								sum = sum * 31 + px[y * bm->stride + x];
						// the hotspot pixel and the first pixel with alpha in [1, 254], to tell whether the
						// bitmap is premultiplied
						int sx = c->hotspot.x, sy = c->hotspot.y;
						const uint8_t *hp = px + sy * bm->stride + sx * 4;
						printf(",\"sum\":%u,\"hotspot_px\":[%u,%u,%u,%u]", sum, hp[0], hp[1], hp[2], hp[3]);
						// premultiplied alpha never has a colour channel above alpha
						uint32_t partial = 0, above = 0, partial_coloured = 0;
						for (uint32_t i = 0; i < bm->size.width * bm->size.height; i++) {
							const uint8_t *q = px + (i / bm->size.width) * bm->stride + (i % bm->size.width) * 4;
							if (q[3] > 0 && q[3] < 255) {
								partial++;
								if (q[0] || q[1] || q[2])
									partial_coloured++;
							}
							if (q[0] > q[3] || q[1] > q[3] || q[2] > q[3])
								above++;
						}
						printf(",\"partial_alpha_px\":%u,\"partial_coloured_px\":%u,"
						       "\"colour_above_alpha_px\":%u",
						       partial, partial_coloured, above);
					}
				}
				printf("}\n");
				p->have_cursor = 1;
				p->last_cursor_id = c->id;
				p->last_x = c->position.x;
				p->last_y = c->position.y;
			}
		}

		if (has_picture) {
			p->pictures++;
			p->window_pictures++;
			if (p->last_picture_s > 0 && t - p->last_picture_s > p->max_gap_s)
				p->max_gap_s = t - p->last_picture_s;
			p->last_picture_s = t;
			struct spa_meta_region *damage = spa_buffer_find_meta_data(buf, SPA_META_VideoDamage, sizeof(*damage));
			printf("{\"ev\":\"frame\",\"t\":%.6f,\"pts\":%lld,\"seq\":%llu,\"size\":%u,\"stride\":%d",
			       t, h ? (long long)h->pts : -1LL, h ? (unsigned long long)h->seq : 0ULL, chunk->size,
			       chunk->stride);
			if (damage) {
				printf(",\"damage\":[");
				int first = 1;
				struct spa_meta *m = spa_buffer_find_meta(buf, SPA_META_VideoDamage);
				struct spa_meta_region *r;
				spa_meta_for_each(r, m) {
					if (!spa_meta_region_is_valid(r))
						break;
					printf("%s[%d,%d,%u,%u]", first ? "" : ",", r->region.position.x, r->region.position.y,
					       r->region.size.width, r->region.size.height);
					first = 0;
				}
				printf("]");
			}
			printf("}\n");
		} else {
			p->cursor_only++;
		}
		if (last)
			pw_stream_queue_buffer(p->stream, last);
		last = b;
	}
	if (last)
		pw_stream_queue_buffer(p->stream, last);
	fflush(stdout);
}

static const struct pw_stream_events stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = on_state_changed,
	.param_changed = on_param_changed,
	.process = on_process,
};

static void on_tick(void *data, uint64_t expirations) {
	struct probe *p = data;
	(void)expirations;
	printf("{\"ev\":\"stats\",\"t\":%.6f,\"buffers\":%llu,\"pictures\":%llu,\"cursor_only\":%llu,\"empty\":%llu,"
	       "\"window_buffers\":%llu,\"window_pictures\":%llu,\"max_gap_ms\":%.2f}\n",
	       now_s(), (unsigned long long)p->buffers, (unsigned long long)p->pictures,
	       (unsigned long long)p->cursor_only, (unsigned long long)p->empty,
	       (unsigned long long)p->window_buffers, (unsigned long long)p->window_pictures, p->max_gap_s * 1000);
	fflush(stdout);
	p->window_buffers = p->window_pictures = 0;
	p->max_gap_s = 0;
}

static void on_quit(void *data, uint64_t expirations) {
	(void)expirations;
	pw_main_loop_quit(((struct probe *)data)->loop);
}

static void on_signal(void *data, int sig) {
	(void)sig;
	pw_main_loop_quit(((struct probe *)data)->loop);
}

int main(int argc, char *argv[]) {
	if (argc < 6) {
		fprintf(stderr, "usage: %s <node-id> <width> <height> <max-fps> <seconds> [bitmaps]\n", argv[0]);
		return 2;
	}
	uint32_t node = atoi(argv[1]), width = atoi(argv[2]), height = atoi(argv[3]), fps = atoi(argv[4]);
	double seconds = atof(argv[5]);
	struct probe p = {0};
	for (int i = 6; i < argc; i++) {
		if (strcmp(argv[i], "bitmaps") == 0) {
			p.dump_bitmaps = 1;
		} else if (strncmp(argv[i], "dmabuf=", 7) == 0) {
			p.dmabuf = 1;
			p.modifier = strtoull(argv[i] + 7, NULL, 0);
		}
	}

	pw_init(&argc, &argv);
	p.loop = pw_main_loop_new(NULL);
	struct pw_loop *l = pw_main_loop_get_loop(p.loop);
	pw_loop_add_signal(l, SIGINT, on_signal, &p);
	pw_loop_add_signal(l, SIGTERM, on_signal, &p);

	char target[32];
	snprintf(target, sizeof(target), "%u", node);
	p.stream = pw_stream_new_simple(l, "lain-spike-b-probe",
					pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
							  PW_KEY_MEDIA_ROLE, "Screen", NULL),
					&stream_events, &p);

	uint8_t buffer[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	const struct spa_pod *params[1];
	struct spa_pod_frame f;
	struct spa_rectangle size = SPA_RECTANGLE(width, height);
	struct spa_fraction zero = SPA_FRACTION(0, 1);
	struct spa_fraction max = SPA_FRACTION(fps, 1);
	struct spa_fraction min = SPA_FRACTION(1, 1);
	spa_pod_builder_push_object(&b, &f, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
	spa_pod_builder_add(&b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
			    SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
			    SPA_POD_CHOICE_ENUM_Id(3, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA),
			    SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&size), SPA_FORMAT_VIDEO_framerate,
			    SPA_POD_Fraction(&zero), SPA_FORMAT_VIDEO_maxFramerate,
			    SPA_POD_CHOICE_RANGE_Fraction(&max, &min, &max), 0);
	if (p.dmabuf) {
		spa_pod_builder_prop(&b, SPA_FORMAT_VIDEO_modifier, SPA_POD_PROP_FLAG_MANDATORY);
		spa_pod_builder_long(&b, (int64_t)p.modifier);
	}
	params[0] = spa_pod_builder_pop(&b, &f);

	pw_stream_connect(p.stream, PW_DIRECTION_INPUT, node,
			  PW_STREAM_FLAG_AUTOCONNECT | (p.dmabuf ? 0 : PW_STREAM_FLAG_MAP_BUFFERS), params, 1);

	struct spa_source *tick = pw_loop_add_timer(l, on_tick, &p);
	struct timespec one = {1, 0};
	pw_loop_update_timer(l, tick, &one, &one, false);
	struct spa_source *quit = pw_loop_add_timer(l, on_quit, &p);
	struct timespec end = {(time_t)seconds, (long)((seconds - (time_t)seconds) * 1e9)};
	pw_loop_update_timer(l, quit, &end, NULL, false);

	pw_main_loop_run(p.loop);
	on_tick(&p, 0);
	pw_stream_destroy(p.stream);
	pw_main_loop_destroy(p.loop);
	pw_deinit();
	return 0;
}
