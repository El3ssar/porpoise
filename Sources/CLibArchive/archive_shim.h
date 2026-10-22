#ifndef PORPOISE_ARCHIVE_SHIM_H
#define PORPOISE_ARCHIVE_SHIM_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
/* macOS ships libarchive and its manual pages but omits the public headers from the SDK.
 * This is the small public C ABI subset used here, declared as in Apple's libarchive:
 * https://github.com/apple-oss-distributions/libarchive/tree/main/libarchive/libarchive
 * The implementation is always the OS library; no bundled binary or downloaded dependency. */
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_zip_seekable(struct archive *);
int archive_read_open_fd(struct archive *, int, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
#endif
