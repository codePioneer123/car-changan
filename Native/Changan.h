#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
int32_t cl_start(const char *local, const char *remote, uint16_t port, const char *pin);
void cl_stop(void);
int32_t cl_state(void);
int32_t cl_format(const uint8_t *bytes, size_t len);
void cl_frame(const uint8_t *bytes, size_t len, int64_t pts, bool key);
int32_t cl_pin(const char *value);
