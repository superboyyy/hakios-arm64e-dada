/*
 * stateexport: what iOS made in /private/var during this boot that the next boot should not have to make again, sent out
 * to the host through RedwoodGPU's export tunnel (boot-arg gpu_export_mb=N; tools/dada-run.sh fetches it as <log>.m2vexp)
 * and baked by ~/hakios-gpu2/tools/varpack.py into the next image's /etc/var.pack, which init unpacks into /private/var
 * before launchd starts (src/init.c, var_pack).
 *
 * Why: /private/var is memory and empty every boot. PosterBoard then renders a gallery picture of every wallpaper there
 * is -- 1.4 to 16.7 s each, their shaders compiled again too -- on all eight cores for a minute and more (dada g2k34),
 * where a real phone does it once and keeps the result in PRBPosterExtensionDataStore.
 *
 * What: the directories in /redwood/etc/stateexport.list (one per line, below /private/var), or the two built in: the
 * wallpapers' data store and the shared shader cache of every mobile process (NativeAdrenoMetalPlugin.mm). The stream is
 * CacheExport.h's ("M2VCACH1", directory "/private/var", per file path below it, mode, owner, group, size, contents)
 * in an "SHEXR001" blob, sent in pieces of 3968 bytes after {magic, 0x7100, generation, total, offset, length}. A blob
 * is sent when the files changed and then stayed unchanged for one period (15 s), so the last one before the run ends
 * is a quiet moment's. Everything is sent every time: the host replaces each directory as a whole, so files iOS
 * removed do not come back. SQLite's -shm files are left out (rebuilt from the -wal), and the shader cache's
 * "imported" mark. Only one sender may use the tunnel: the plug-in's own export stays off while this job is installed.
 *
 * Runs as root (com.redwood.stateexport), which reads mobile's files; it only reads.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define ROOT            "/private/var"
#define MAGIC           0x4e544e4cu
#define PROBE           0xffffffffu
#define METHOD          0x7100u
#define PIECE           3968u
#define LIMIT           (240u << 20)     /* (with boot-arg gpu_export_mb=256: the icons' cache and the shared shader cache made 150 MB, g2k51) */
#define MAX_FILES       20000
#define PERIOD          15

static const char *builtin[] = {
	"mobile/Library/Application Support/PRBPosterExtensionDataStore",
	"mobile/Library/Caches/com.redwood.m2v-shared",
	/* the icons' cache, iConServices' (iOS 26: a system group container of a fixed name, 55 MB after a boot, g2k50) */
	"containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache",
};

struct file {
	char *path;             /* below ROOT */
	struct stat st;
};

static struct file files[MAX_FILES];
static unsigned nfiles;
static io_connect_t conn;
static uint32_t selector;

static int
skipped(const char *name)
{
	size_t n = strlen(name);

	return (n > 4 && strcmp(name + n - 4, "-shm") == 0) || strcmp(name, "imported") == 0;
}

static void
scan(const char *relative, unsigned depth)
{
	char full[2048];
	DIR *dir;
	struct dirent *entry;

	if (depth > 12) {
		return;
	}
	snprintf(full, sizeof(full), ROOT "/%s", relative);
	if ((dir = opendir(full)) == NULL) {
		return;
	}
	while ((entry = readdir(dir)) != NULL && nfiles < MAX_FILES) {
		char path[1024];
		struct stat st;

		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0 || skipped(entry->d_name)) {
			continue;
		}
		snprintf(path, sizeof(path), "%s/%s", relative, entry->d_name);
		snprintf(full, sizeof(full), ROOT "/%s", path);
		if (lstat(full, &st) != 0) {
			continue;
		}
		if (S_ISDIR(st.st_mode)) {
			scan(path, depth + 1);
		} else if (S_ISREG(st.st_mode)) {
			files[nfiles].path = strdup(path);
			files[nfiles].st = st;
			nfiles++;
		}
	}
	closedir(dir);
}

static void
scan_all(void)
{
	FILE *list = fopen("/redwood/etc/stateexport.list", "r");
	char line[1024];

	for (unsigned i = 0; i < nfiles; i++) {
		free(files[i].path);
	}
	nfiles = 0;
	if (list == NULL) {
		for (unsigned i = 0; i < sizeof(builtin) / sizeof(builtin[0]); i++) {
			scan(builtin[i], 0);
		}
		return;
	}
	while (fgets(line, sizeof(line), list) != NULL) {
		line[strcspn(line, "\r\n")] = 0;
		if (line[0] != 0 && line[0] != '#' && line[0] != '/' && strstr(line, "..") == NULL) {
			scan(line, 0);
		}
	}
	fclose(list);
}

/* bytes under a directory (8 levels at most) */
static uint64_t
du(const char *path, unsigned depth)
{
	DIR *dir = depth < 8 ? opendir(path) : NULL;
	struct dirent *entry;
	uint64_t total = 0;

	if (dir == NULL) {
		return 0;
	}
	while ((entry = readdir(dir)) != NULL) {
		char child[2048];
		struct stat st;

		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
			continue;
		}
		snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
		if (lstat(child, &st) != 0) {
			continue;
		}
		total += S_ISDIR(st.st_mode) ? du(child, depth + 1) : (uint64_t)st.st_size;
	}
	closedir(dir);
	return total;
}

/* a container's identifier, from its .com.apple.mobile_container_manager.metadata.plist */
static void
container_identifier(const char *path, char *out, size_t size)
{
	char plist[2048];
	CFURLRef url;
	CFReadStreamRef stream;

	snprintf(out, size, "?");
	snprintf(plist, sizeof(plist), "%s/.com.apple.mobile_container_manager.metadata.plist", path);
	url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)plist, (CFIndex)strlen(plist), false);
	stream = url ? CFReadStreamCreateWithFile(NULL, url) : NULL;
	if (stream != NULL && CFReadStreamOpen(stream)) {
		CFPropertyListRef list = CFPropertyListCreateWithStream(NULL, stream, 0, kCFPropertyListImmutable, NULL, NULL);

		if (list != NULL && CFGetTypeID(list) == CFDictionaryGetTypeID()) {
			CFStringRef id = CFDictionaryGetValue(list, CFSTR("MCMMetadataIdentifier"));

			if (id != NULL && CFGetTypeID(id) == CFStringGetTypeID()) {
				CFStringGetCString(id, out, (CFIndex)size, kCFStringEncodingUTF8);
			}
		}
		if (list != NULL) {
			CFRelease(list);
		}
		CFReadStreamClose(stream);
	}
	if (stream != NULL) {
		CFRelease(stream);
	}
	if (url != NULL) {
		CFRelease(url);
	}
}

/*
 * Once, 90 s into the run: what of /private/var is big, for choosing what else to bake (the icons' cache, iOS 26, lives in a
 * system group container whose directory is a new UUID every boot): the directories under mobile/Library/Caches and the
 * system group containers, with their identifiers, 256 KB and up.
 */
static void
report(void)
{
	static const char *places[] = { "/private/var/mobile/Library/Caches", "/private/var/containers/Shared/SystemGroup",
		                         "/private/var/mobile/Library/Application Support" };

	for (unsigned i = 0; i < sizeof(places) / sizeof(places[0]); i++) {
		DIR *dir = opendir(places[i]);
		struct dirent *entry;

		while (dir != NULL && (entry = readdir(dir)) != NULL) {
			char child[2048], id[256];
			uint64_t bytes;

			if (entry->d_name[0] == '.') {
				continue;
			}
			snprintf(child, sizeof(child), "%s/%s", places[i], entry->d_name);
			bytes = du(child, 0);
			if (bytes < (256u << 10)) {
				continue;
			}
			container_identifier(child, id, sizeof(id));
			printf("stateexport: %s: %llu KB (%s)\n", child, (unsigned long long)(bytes >> 10), id);
		}
		if (dir != NULL) {
			closedir(dir);
		}
	}
}

/* count, sizes and times of the files: equal twice = nothing is being written */
static uint64_t
signature(void)
{
	uint64_t s = nfiles * 0x9e3779b97f4a7c15ull;

	for (unsigned i = 0; i < nfiles; i++) {
		s = s * 31 + (uint64_t)files[i].st.st_size * 1000003 + (uint64_t)files[i].st.st_mtimespec.tv_sec * 7 +
		    (uint64_t)files[i].st.st_mtimespec.tv_nsec;
	}
	return s;
}

/* the sender: pieces of the blob, each after its header */
static uint8_t piece[24 + PIECE];
static uint32_t filled, offset, total, generation;
static int sent_ok;

static int
flush(void)
{
	uint32_t head[6] = { MAGIC, METHOD, generation, total, offset, filled };

	memcpy(piece, head, sizeof(head));
	sent_ok = IOConnectCallStructMethod(conn, selector, piece, sizeof(head) + filled, NULL, NULL) == KERN_SUCCESS;
	offset += filled;
	filled = 0;
	return sent_ok;
}

static int
emit(const void *p, size_t n)
{
	const uint8_t *b = p;

	while (n > 0) {
		size_t k = n < PIECE - filled ? n : PIECE - filled;

		memcpy(piece + 24 + filled, b, k);
		filled += (uint32_t)k;
		b += k;
		n -= k;
		if (filled == PIECE && !flush()) {
			return 0;
		}
	}
	return 1;
}

static int
emit32(uint32_t v)
{
	return emit(&v, 4);
}

/* one blob of every file; 0 when a file changed meanwhile or a piece was refused */
static int
send_all(void)
{
	static uint8_t chunk[65536];
	uint64_t stream = 8 + 4 + strlen(ROOT) + 4;
	uint8_t head[16] = { 'S', 'H', 'E', 'X', 'R', '0', '0', '1' };

	for (unsigned i = 0; i < nfiles; i++) {
		stream += 24 + strlen(files[i].path) + (uint64_t)files[i].st.st_size;
	}
	if (16 + stream > LIMIT) {
		printf("stateexport: %u files, %llu bytes: more than one export takes\n", nfiles, (unsigned long long)stream);
		return -1;
	}
	total = (uint32_t)(16 + stream);
	offset = filled = 0;
	generation++;
	memcpy(head + 8, &(uint32_t){ (uint32_t)stream }, 4);
	if (!emit(head, 16) || !emit("M2VCACH1", 8) || !emit32((uint32_t)strlen(ROOT)) || !emit(ROOT, strlen(ROOT)) ||
	    !emit32(nfiles)) {
		return 0;
	}
	for (unsigned i = 0; i < nfiles; i++) {
		char full[2048];
		uint64_t size = (uint64_t)files[i].st.st_size, left = size;
		FILE *in;
		int ok;

		snprintf(full, sizeof(full), ROOT "/%s", files[i].path);
		if ((in = fopen(full, "rb")) == NULL) {
			return 0;
		}
		ok = emit32((uint32_t)strlen(files[i].path)) && emit32((uint32_t)files[i].st.st_mode) &&
		    emit32((uint32_t)files[i].st.st_uid) && emit32((uint32_t)files[i].st.st_gid) && emit(&size, 8) &&
		    emit(files[i].path, strlen(files[i].path));
		while (ok && left > 0) {
			size_t want = left < sizeof(chunk) ? (size_t)left : sizeof(chunk);

			ok = fread(chunk, 1, want, in) == want && emit(chunk, want);
			left -= want;
		}
		ok = ok && fgetc(in) == EOF;    /* grown since the scan: refuse rather than send a short copy */
		fclose(in);
		if (!ok) {
			return 0;
		}
	}
	if (filled > 0 && !flush()) {
		return 0;
	}
	return offset == total;
}

int
main(void)
{
	io_service_t service;

	setvbuf(stdout, NULL, _IOLBF, 0);       /* (the console is a file to launchd: whole lines, not 4 KB at a time) */
	printf("stateexport: started, uid %d\n", getuid());
	service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("RedwoodGPU"));
	uint64_t previous = 0, exported = 0;
	unsigned unquiet = 0;
	uint64_t largest = 0;
	int found = 0;

	if (service == IO_OBJECT_NULL || IOServiceOpen(service, mach_task_self(), 0x4148, &conn) != KERN_SUCCESS) {
		printf("stateexport: no RedwoodGPU connection\n");
		return 1;
	}
	for (uint32_t s = 0; s < 256 && !found; s++) {
		uint32_t probe[2] = { MAGIC, PROBE };

		if (IOConnectCallStructMethod(conn, s, probe, sizeof(probe), NULL, NULL) == KERN_SUCCESS) {
			selector = s;
			found = 1;
		}
	}
	if (!found) {
		printf("stateexport: the tunnel answers no selector\n");
		return 1;
	}
	printf("stateexport: watching, selector %u\n", selector);
	for (unsigned period = 0;; period++) {
		uint64_t now;

		sleep(PERIOD);
		if (period == 90 / PERIOD) {
			report();
		}
		scan_all();
		now = signature();
		/*
		 * (a quiet period, or 45 s since the last export with changes in them anyway: PosterBoard's database is written now and
		 * then all run long, never quiet for a period, and only the first, nearly empty export went out (g2k50: 96 KB of a
		 * 6.6 MB store))
		 */
		if (now != previous && ++unquiet < 45 / PERIOD) {
			previous = now;
			continue;
		}
		previous = now;
		unquiet = 0;
		if (now == exported || nfiles == 0) {
			continue;
		}
		/*
		 * (and not when it has shrunk: iOS trims these caches late in a run -- g2k51's last export had 1.2 of the icons' 55 MB
		 * and 96 KB of PosterBoard's 6.6 MB -- and the kernel keeps only the last export)
		 */
		{
			uint64_t bytes = 0;

			for (unsigned i = 0; i < nfiles; i++) {
				bytes += (uint64_t)files[i].st.st_size;
			}
			if (bytes < largest / 10 * 9) {
				continue;
			}
			largest = bytes > largest ? bytes : largest;
		}
		int sent = send_all();

		if (sent != 0) {
			exported = now;         /* (too big: said once, not every period) */
		}
		if (sent > 0) {
			printf("stateexport: export %u: %u files, %u KB\n", generation, nfiles, total >> 10);
		} else {
			printf("stateexport: export %u not sent (%s)\n", generation, sent_ok ? "a file changed" : "a piece refused");
		}
	}
}
