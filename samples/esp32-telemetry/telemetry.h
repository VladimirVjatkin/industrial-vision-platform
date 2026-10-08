#ifndef SAMPLE_TELEMETRY_H
#define SAMPLE_TELEMETRY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TLM_MAX_SENSORS 3
#define TLM_MAX_BUFFER 16
#define TLM_JSON_SIZE 512

typedef enum {
    TLM_OK,
    TLM_SUSPECT,
    TLM_NOT_FOUND,
    TLM_CRC_ERROR,
    TLM_CONVERSION_TIMEOUT
} tlm_quality;

typedef enum { TLM_UNSYNCED, TLM_SYNCED } tlm_time_quality;

typedef struct {
    char sensor_id[17];
    uint64_t next_seq;
} tlm_sensor_seq;

typedef struct {
    char node_id[33];
    char boot_id[37];
    char firmware_version[33];
    tlm_sensor_seq sensors[TLM_MAX_SENSORS];
    size_t sensor_count;
} tlm_node;

typedef struct {
    char node_id[33];
    char sensor_id[17];
    char boot_id[37];
    char firmware_version[33];
    char measured_at[21];
    uint64_t seq;
    uint64_t uptime_ms;
    uint64_t captured_ms;
    int32_t value_centi_c;
    tlm_quality quality;
    tlm_time_quality time_quality;
    bool has_value;
    bool connected_at_capture;
} tlm_record;

typedef struct {
    tlm_record record;
    uint64_t last_attempt_ms;
    bool attempted;
} tlm_pending;

typedef struct {
    tlm_pending items[TLM_MAX_BUFFER];
    size_t capacity;
    size_t head;
    size_t count;
    uint64_t dropped;
    uint64_t rejected;
} tlm_queue;

typedef enum { TLM_ACK_IGNORED, TLM_ACK_REMOVED } tlm_ack_result;

/* Caller supplies fresh random bytes for each boot; this module does not source entropy. */
bool tlm_node_init(tlm_node *node, const char *node_id, const char *version,
                   const uint8_t entropy[16]);
bool tlm_queue_init(tlm_queue *queue, size_t capacity);

/* A record is retained before publication. No sequence is consumed on invalid input. */
bool tlm_enqueue(tlm_queue *queue, tlm_node *node, const char *sensor_id,
                 tlm_quality quality, bool has_value, int32_t value_centi_c,
                 tlm_time_quality time_quality, const char *measured_at,
                 uint64_t uptime_ms, uint64_t captured_ms, bool connected_at_capture,
                 tlm_record *created);

/* at_capture is true only for a synchronous first send after enqueue. */
bool tlm_prepare_next(tlm_queue *queue, uint64_t now_ms, uint64_t resend_after_ms,
                      bool at_capture, tlm_record *record, bool *buffered);
void tlm_publish_failed(tlm_queue *queue, const tlm_record *record);

/* Validates a bounded, flat JSON acknowledgement; malformed/unknown ACKs are ignored. */
tlm_ack_result tlm_handle_ack_json(tlm_queue *queue, const char *json);

bool tlm_measurement_json(const tlm_record *record, bool buffered,
                          char out[TLM_JSON_SIZE]);
bool tlm_status_json(const tlm_node *node, const tlm_queue *queue,
                     uint64_t uptime_ms, tlm_time_quality time_quality,
                     int wifi_rssi, unsigned sensors_found, char out[TLM_JSON_SIZE]);
const char *tlm_availability(bool online);

#endif
