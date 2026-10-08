#include "telemetry.h"

#include <ctype.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

static bool node_id_valid(const char *s)
{
    size_t n = strlen(s);
    if (n < 3 || n > 32) return false;
    for (size_t i = 0; i < n; ++i)
        if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9') || s[i] == '-'))
            return false;
    return true;
}

static bool sensor_id_valid(const char *s)
{
    if (strlen(s) != 16 || s[0] != '2' || s[1] != '8') return false;
    for (size_t i = 0; i < 16; ++i)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'A' && s[i] <= 'F')))
            return false;
    return true;
}

static bool timestamp_valid(const char *s)
{
    if (!s || strlen(s) != 20) return false;
    for (size_t i = 0; i < 20; ++i) {
        if (i == 4 || i == 7) { if (s[i] != '-') return false; }
        else if (i == 10) { if (s[i] != 'T') return false; }
        else if (i == 13 || i == 16) { if (s[i] != ':') return false; }
        else if (i == 19) { if (s[i] != 'Z') return false; }
        else if (!isdigit((unsigned char)s[i])) return false;
    }
    return true;
}

static bool escaped_version(const char *s, char out[193])
{
    size_t used = 0;
    for (; *s; ++s) {
        unsigned char c = (unsigned char)*s;
        if (c < 0x20) return false;
        if (c == '"' || c == '\\') {
            if (used + 2 >= 193) return false;
            out[used++] = '\\';
        } else if (used + 1 >= 193) return false;
        out[used++] = (char)c;
    }
    out[used] = '\0';
    return true;
}

bool tlm_node_init(tlm_node *node, const char *node_id, const char *version,
                   const uint8_t entropy[16])
{
    if (!node || !node_id || !version || !entropy || !node_id_valid(node_id) ||
        strlen(version) > 32) return false;
    char escaped[193];
    if (!escaped_version(version, escaped)) return false;
    memset(node, 0, sizeof(*node));
    memcpy(node->node_id, node_id, strlen(node_id) + 1);
    memcpy(node->firmware_version, version, strlen(version) + 1);
    uint8_t b[16];
    memcpy(b, entropy, sizeof(b));
    b[6] = (uint8_t)((b[6] & 0x0f) | 0x40);
    b[8] = (uint8_t)((b[8] & 0x3f) | 0x80);
    int n = snprintf(node->boot_id, sizeof(node->boot_id),
                     "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                     b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                     b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
    return n == 36;
}

bool tlm_queue_init(tlm_queue *queue, size_t capacity)
{
    if (!queue || capacity == 0 || capacity > TLM_MAX_BUFFER) return false;
    memset(queue, 0, sizeof(*queue));
    queue->capacity = capacity;
    return true;
}

static tlm_pending *item_at(tlm_queue *queue, size_t index)
{
    return &queue->items[(queue->head + index) % queue->capacity];
}

static void remove_at(tlm_queue *queue, size_t index)
{
    for (size_t i = index; i + 1 < queue->count; ++i)
        *item_at(queue, i) = *item_at(queue, i + 1);
    --queue->count;
}

static bool reading_valid(tlm_quality quality, bool has_value, int32_t value,
                          tlm_time_quality time_quality, const char *timestamp)
{
    if (quality < TLM_OK || quality > TLM_CONVERSION_TIMEOUT ||
        (time_quality != TLM_SYNCED && time_quality != TLM_UNSYNCED)) return false;
    if (has_value != (quality == TLM_OK || quality == TLM_SUSPECT)) return false;
    if (has_value && (value < -5500 || value > 12500)) return false;
    if (time_quality == TLM_SYNCED) return timestamp_valid(timestamp);
    return !timestamp || !*timestamp;
}

bool tlm_enqueue(tlm_queue *queue, tlm_node *node, const char *sensor_id,
                 tlm_quality quality, bool has_value, int32_t value_centi_c,
                 tlm_time_quality time_quality, const char *measured_at,
                 uint64_t uptime_ms, uint64_t captured_ms, bool connected_at_capture,
                 tlm_record *created)
{
    if (!queue || !node || !sensor_id || !queue->capacity ||
        !sensor_id_valid(sensor_id) ||
        !reading_valid(quality, has_value, value_centi_c, time_quality, measured_at))
        return false;
    size_t slot = 0;
    while (slot < node->sensor_count && strcmp(node->sensors[slot].sensor_id, sensor_id)) ++slot;
    if (slot == TLM_MAX_SENSORS ||
        (slot < node->sensor_count && node->sensors[slot].next_seq == UINT64_MAX)) return false;
    if (slot == node->sensor_count) {
        memcpy(node->sensors[slot].sensor_id, sensor_id, 17);
        node->sensor_count++;
    }
    uint64_t seq = node->sensors[slot].next_seq++;
    if (queue->count == queue->capacity) {
        queue->head = (queue->head + 1) % queue->capacity;
        --queue->count;
        ++queue->dropped;
    }
    tlm_pending *pending = item_at(queue, queue->count++);
    memset(pending, 0, sizeof(*pending));
    tlm_record *r = &pending->record;
    memcpy(r->node_id, node->node_id, sizeof(r->node_id));
    memcpy(r->sensor_id, sensor_id, sizeof(r->sensor_id));
    memcpy(r->boot_id, node->boot_id, sizeof(r->boot_id));
    memcpy(r->firmware_version, node->firmware_version, sizeof(r->firmware_version));
    if (time_quality == TLM_SYNCED) memcpy(r->measured_at, measured_at, sizeof(r->measured_at));
    r->seq = seq;
    r->uptime_ms = uptime_ms;
    r->captured_ms = captured_ms;
    r->quality = quality;
    r->has_value = has_value;
    r->value_centi_c = has_value ? value_centi_c : 0;
    r->time_quality = time_quality;
    r->connected_at_capture = connected_at_capture;
    if (created) *created = *r;
    return true;
}

bool tlm_prepare_next(tlm_queue *queue, uint64_t now_ms, uint64_t resend_after_ms,
                      bool at_capture, tlm_record *record, bool *buffered)
{
    if (!queue || !queue->capacity || !record || !buffered || !resend_after_ms) return false;
    for (size_t i = 0; i < queue->count; ++i) {
        tlm_pending *p = item_at(queue, i);
        if (p->attempted && (now_ms < p->last_attempt_ms ||
            now_ms - p->last_attempt_ms < resend_after_ms)) continue;
        *buffered = !(at_capture && !p->attempted && p->record.connected_at_capture &&
                      p->record.captured_ms == now_ms);
        *record = p->record;
        p->attempted = true;  /* Mark before the transport call: ACK may arrive immediately. */
        p->last_attempt_ms = now_ms;
        return true;
    }
    return false;
}

void tlm_publish_failed(tlm_queue *queue, const tlm_record *record)
{
    if (!queue || !queue->capacity || !record) return;
    for (size_t i = 0; i < queue->count; ++i) {
        tlm_pending *p = item_at(queue, i);
        if (p->record.seq == record->seq && !strcmp(p->record.boot_id, record->boot_id) &&
            !strcmp(p->record.sensor_id, record->sensor_id)) {
            p->attempted = false;
            return;
        }
    }
}

static void space(const char **p)
{
    while (**p == ' ' || **p == '\t' || **p == '\r' || **p == '\n') ++*p;
}

static bool string_token(const char **p, char *out, size_t size)
{
    if (**p != '"') return false;
    ++*p;
    size_t n = 0;
    while (**p && **p != '"') {
        unsigned char c = (unsigned char)**p;
        if (c < 0x20 || c == '\\' || n + 1 >= size) return false;
        out[n++] = (char)c;
        ++*p;
    }
    if (**p != '"') return false;
    ++*p;
    out[n] = '\0';
    return true;
}

static bool uint_token(const char **p, uint64_t *value)
{
    if (**p < '0' || **p > '9') return false;
    uint64_t n = 0;
    do {
        unsigned digit = (unsigned)(**p - '0');
        if (n > (UINT64_MAX - digit) / 10) return false;
        n = n * 10 + digit;
        ++*p;
    } while (**p >= '0' && **p <= '9');
    *value = n;
    return true;
}

tlm_ack_result tlm_handle_ack_json(tlm_queue *queue, const char *json)
{
    if (!queue || !queue->capacity || !json || strlen(json) > 384) return TLM_ACK_IGNORED;
    const char *p = json;
    char sensor[17] = "", boot[37] = "", result[16] = "";
    uint64_t schema = 0, seq = 0;
    unsigned seen = 0;
    space(&p);
    if (*p++ != '{') return TLM_ACK_IGNORED;
    for (;;) {
        char key[32];
        space(&p);
        if (!string_token(&p, key, sizeof(key))) return TLM_ACK_IGNORED;
        space(&p);
        if (*p++ != ':') return TLM_ACK_IGNORED;
        space(&p);
        unsigned bit;
        if (!strcmp(key, "schema_version")) {
            bit = 1;
            if (!uint_token(&p, &schema)) return TLM_ACK_IGNORED;
        } else if (!strcmp(key, "sensor_id")) {
            bit = 2;
            if (!string_token(&p, sensor, sizeof(sensor))) return TLM_ACK_IGNORED;
        } else if (!strcmp(key, "boot_id")) {
            bit = 4;
            if (!string_token(&p, boot, sizeof(boot))) return TLM_ACK_IGNORED;
        } else if (!strcmp(key, "seq")) {
            bit = 8;
            if (!uint_token(&p, &seq)) return TLM_ACK_IGNORED;
        } else if (!strcmp(key, "result")) {
            bit = 16;
            if (!string_token(&p, result, sizeof(result))) return TLM_ACK_IGNORED;
        } else return TLM_ACK_IGNORED;
        if (seen & bit) return TLM_ACK_IGNORED;
        seen |= bit;
        space(&p);
        if (*p == '}') { ++p; break; }
        if (*p++ != ',') return TLM_ACK_IGNORED;
    }
    space(&p);
    if (*p || seen != 31 || schema != 1 || !sensor_id_valid(sensor) ||
        (strcmp(result, "stored") && strcmp(result, "duplicate") && strcmp(result, "rejected")))
        return TLM_ACK_IGNORED;
    for (size_t i = 0; i < queue->count; ++i) {
        tlm_record *r = &item_at(queue, i)->record;
        if (!strcmp(r->boot_id, boot) && !strcmp(r->sensor_id, sensor) && r->seq == seq) {
            if (!strcmp(result, "rejected")) ++queue->rejected;
            remove_at(queue, i);
            return TLM_ACK_REMOVED;
        }
    }
    return TLM_ACK_IGNORED;
}

static const char *quality_name(tlm_quality quality)
{
    static const char *names[] = {"ok", "suspect", "not_found", "crc_error", "conversion_timeout"};
    return quality >= TLM_OK && quality <= TLM_CONVERSION_TIMEOUT ? names[quality] : NULL;
}

bool tlm_measurement_json(const tlm_record *r, bool buffered, char out[TLM_JSON_SIZE])
{
    if (!r || !out || !quality_name(r->quality)) return false;
    char version[193], value[24], timestamp[24];
    if (!escaped_version(r->firmware_version, version)) return false;
    if (r->has_value) {
        int64_t centi = r->value_centi_c;
        uint64_t magnitude = centi < 0 ? (uint64_t)-centi : (uint64_t)centi;
        snprintf(value, sizeof(value), "%s%" PRIu64 ".%02" PRIu64,
                 centi < 0 ? "-" : "", magnitude / 100, magnitude % 100);
    } else memcpy(value, "null", sizeof("null"));
    if (r->time_quality == TLM_SYNCED)
        snprintf(timestamp, sizeof(timestamp), "\"%s\"", r->measured_at);
    else memcpy(timestamp, "null", sizeof("null"));
    int n = snprintf(out, TLM_JSON_SIZE,
        "{\"schema_version\":1,\"node_id\":\"%s\",\"sensor_id\":\"%s\","
        "\"boot_id\":\"%s\",\"seq\":%" PRIu64 ",\"measured_at\":%s,"
        "\"uptime_ms\":%" PRIu64 ",\"value\":%s,\"unit\":\"C\","
        "\"quality\":\"%s\",\"time_quality\":\"%s\",\"buffered\":%s,"
        "\"firmware_version\":\"%s\"}",
        r->node_id, r->sensor_id, r->boot_id, r->seq, timestamp, r->uptime_ms,
        value, quality_name(r->quality), r->time_quality == TLM_SYNCED ? "synced" : "unsynced",
        buffered ? "true" : "false", version);
    return n > 0 && n < TLM_JSON_SIZE;
}

bool tlm_status_json(const tlm_node *node, const tlm_queue *queue,
                     uint64_t uptime_ms, tlm_time_quality time_quality,
                     int wifi_rssi, unsigned sensors_found, char out[TLM_JSON_SIZE])
{
    if (!node || !queue || !out || sensors_found > TLM_MAX_SENSORS ||
        (time_quality != TLM_SYNCED && time_quality != TLM_UNSYNCED)) return false;
    char version[193];
    if (!escaped_version(node->firmware_version, version)) return false;
    int n = snprintf(out, TLM_JSON_SIZE,
        "{\"schema_version\":1,\"node_id\":\"%s\",\"boot_id\":\"%s\","
        "\"uptime_ms\":%" PRIu64 ",\"time_quality\":\"%s\",\"wifi_rssi\":%d,"
        "\"sensors_found\":%u,\"buffer_depth\":%zu,\"buffer_dropped\":%" PRIu64 ","
        "\"firmware_version\":\"%s\"}",
        node->node_id, node->boot_id, uptime_ms,
        time_quality == TLM_SYNCED ? "synced" : "unsynced", wifi_rssi,
        sensors_found, queue->count, queue->dropped, version);
    return n > 0 && n < TLM_JSON_SIZE;
}

const char *tlm_availability(bool online)
{
    return online ? "online" : "offline";
}
