#include "telemetry.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

#define SENSOR_A "28AA000000000001"
#define SENSOR_B "28AA000000000002"
#define SENSOR_C "28AA000000000003"
#define SENSOR_D "28AA000000000004"

static tlm_node make_node(uint8_t first)
{
    uint8_t entropy[16];
    for (unsigned i = 0; i < 16; ++i) entropy[i] = (uint8_t)(first + i);
    tlm_node node;
    assert(tlm_node_init(&node, "sample-node-a", "sample-1", entropy));
    assert(node.boot_id[14] == '4');
    assert(node.boot_id[19] == '8' || node.boot_id[19] == '9' ||
           node.boot_id[19] == 'a' || node.boot_id[19] == 'b');
    return node;
}

static void ack_text(char out[256], const tlm_record *r, const char *result)
{
    int n = snprintf(out, 256,
        "{\"result\":\"%s\",\"seq\":%llu,\"boot_id\":\"%s\","
        "\"sensor_id\":\"%s\",\"schema_version\":1}",
        result, (unsigned long long)r->seq, r->boot_id, r->sensor_id);
    assert(n > 0 && n < 256);
}

static void test_identity_and_json(void)
{
    uint8_t entropy[16] = {0};
    tlm_node invalid;
    assert(!tlm_node_init(&invalid, "BAD NODE", "sample-1", entropy));
    tlm_node node = make_node(0);
    tlm_queue q;
    assert(tlm_queue_init(&q, 3));
    tlm_record r, selected;
    bool buffered;
    assert(!tlm_enqueue(&q, &node, SENSOR_A, TLM_NOT_FOUND, true, 0,
                        TLM_UNSYNCED, NULL, 100, 1000, true, NULL));
    assert(!tlm_enqueue(&q, &node, SENSOR_A, TLM_OK, true, -1825,
                        TLM_SYNCED, "not-a-time", 100, 1000, true, NULL));
    assert(tlm_enqueue(&q, &node, SENSOR_A, TLM_OK, true, -1825,
                       TLM_SYNCED, "2026-01-15T10:00:00Z", 100, 1000, true, &r));
    assert(r.seq == 0 && node.sensor_count == 1 && q.count == 1);
    assert(tlm_prepare_next(&q, 1000, 300000, true, &selected, &buffered));
    assert(!buffered && selected.seq == 0);
    char first[TLM_JSON_SIZE], retry[TLM_JSON_SIZE];
    assert(tlm_measurement_json(&selected, buffered, first));
    assert(strstr(first, "\"value\":-18.25") != NULL);
    assert(strstr(first, "\"measured_at\":\"2026-01-15T10:00:00Z\"") != NULL);
    assert(strstr(first, "\"buffered\":false") != NULL);
    assert(!tlm_prepare_next(&q, 1001, 300000, false, &selected, &buffered));
    assert(tlm_prepare_next(&q, 301000, 300000, false, &selected, &buffered));
    assert(buffered);
    assert(tlm_measurement_json(&selected, buffered, retry));
    char expected[TLM_JSON_SIZE];
    memcpy(expected, first, strlen(first) + 1);
    char *flag = strstr(expected, "\"buffered\":false");
    assert(flag);
    size_t offset = (size_t)(flag - expected);
    memmove(expected + offset + 15, expected + offset + 16,
            strlen(expected + offset + 16) + 1);
    memcpy(expected + offset, "\"buffered\":true", 15);
    assert(strcmp(expected, retry) == 0);
    puts("PASS: boot UUID, validation and stable retry JSON");
}

static void test_ack_and_sequence(void)
{
    tlm_node node = make_node(10);
    tlm_queue q;
    assert(tlm_queue_init(&q, 3));
    tlm_record a0, a1, b0;
    assert(tlm_enqueue(&q, &node, SENSOR_A, TLM_OK, true, 8500,
                       TLM_UNSYNCED, NULL, 100, 1000, false, &a0));
    assert(tlm_enqueue(&q, &node, SENSOR_A, TLM_SUSPECT, true, 8500,
                       TLM_UNSYNCED, NULL, 200, 2000, false, &a1));
    assert(tlm_enqueue(&q, &node, SENSOR_B, TLM_NOT_FOUND, false, 0,
                       TLM_UNSYNCED, NULL, 200, 2000, false, &b0));
    assert(a0.seq == 0 && a1.seq == 1 && b0.seq == 0);
    char json[TLM_JSON_SIZE], ack[256];
    assert(tlm_measurement_json(&b0, true, json));
    assert(strstr(json, "\"value\":null") && strstr(json, "\"measured_at\":null"));
    assert(strstr(json, "\"time_quality\":\"unsynced\""));
    assert(tlm_handle_ack_json(&q, "{bad json") == TLM_ACK_IGNORED);
    ack_text(ack, &a0, "stored");
    assert(tlm_handle_ack_json(&q, ack) == TLM_ACK_REMOVED && q.count == 2);
    assert(tlm_handle_ack_json(&q, ack) == TLM_ACK_IGNORED && q.count == 2);
    ack_text(ack, &a1, "rejected");
    assert(tlm_handle_ack_json(&q, ack) == TLM_ACK_REMOVED && q.rejected == 1);
    ack_text(ack, &b0, "duplicate");
    assert(tlm_handle_ack_json(&q, ack) == TLM_ACK_REMOVED && q.count == 0);
    tlm_node rebooted = make_node(20);
    tlm_record next;
    assert(tlm_enqueue(&q, &rebooted, SENSOR_A, TLM_OK, true, -1800,
                       TLM_UNSYNCED, NULL, 100, 1000, false, &next));
    assert(next.seq == 0 && strcmp(next.boot_id, a0.boot_id) != 0);
    ack_text(ack, &a0, "stored");
    assert(tlm_handle_ack_json(&q, ack) == TLM_ACK_IGNORED && q.count == 1);
    puts("PASS: per-sensor sequence, reboot identity and ACK outcomes");
}

static void test_buffer_and_status(void)
{
    tlm_node node = make_node(30);
    tlm_queue q;
    assert(tlm_queue_init(&q, 2));
    tlm_record a, b, c, selected;
    bool buffered;
    assert(tlm_enqueue(&q, &node, SENSOR_A, TLM_OK, true, -1800,
                       TLM_UNSYNCED, NULL, 100, 1000, false, &a));
    assert(tlm_enqueue(&q, &node, SENSOR_B, TLM_CRC_ERROR, false, 0,
                       TLM_UNSYNCED, NULL, 200, 2000, true, &b));
    assert(tlm_enqueue(&q, &node, SENSOR_C, TLM_CONVERSION_TIMEOUT, false, 0,
                       TLM_UNSYNCED, NULL, 300, 3000, true, &c));
    assert(q.count == 2 && q.dropped == 1);
    assert(tlm_prepare_next(&q, 4000, 300000, false, &selected, &buffered));
    assert(strcmp(selected.sensor_id, SENSOR_B) == 0 && buffered);
    tlm_publish_failed(&q, &selected);
    assert(tlm_prepare_next(&q, 4001, 300000, false, &selected, &buffered));
    assert(strcmp(selected.sensor_id, SENSOR_B) == 0 && buffered);
    char status[TLM_JSON_SIZE];
    assert(tlm_status_json(&node, &q, 4001, TLM_UNSYNCED, -60, 3, status));
    assert(strstr(status, "\"buffer_depth\":2") &&
           strstr(status, "\"buffer_dropped\":1"));
    assert(!strcmp(tlm_availability(true), "online"));
    assert(!strcmp(tlm_availability(false), "offline"));
    assert(!tlm_enqueue(&q, &node, SENSOR_D, TLM_OK, true, 0,
                        TLM_UNSYNCED, NULL, 400, 4000, false, NULL));
    puts("PASS: oldest-first eviction, failed publish retry and status");
}

static void test_ack_rejection_and_escaping(void)
{
    tlm_node node = make_node(40);
    tlm_queue q;
    assert(tlm_queue_init(&q, 1));
    tlm_record r;
    assert(tlm_enqueue(&q, &node, SENSOR_A, TLM_OK, true, 250,
                       TLM_UNSYNCED, NULL, 100, 1000, true, &r));
    char ack[256], altered[256];
    ack_text(ack, &r, "stored");
    memcpy(altered, ack, strlen(ack) + 1);
    char *field = strstr(altered, "\"schema_version\":1");
    assert(field);
    field[strlen("\"schema_version\":")] = '2';
    assert(tlm_handle_ack_json(&q, altered) == TLM_ACK_IGNORED);
    memcpy(altered, ack, strlen(ack) + 1);
    field = strstr(altered, "\"result\":\"stored\"");
    assert(field);
    memcpy(field + strlen("\"result\":\""), "bogus\"", 6);
    assert(tlm_handle_ack_json(&q, altered) == TLM_ACK_IGNORED);
    memcpy(altered, ack, strlen(ack) + 1);
    field = strstr(altered, SENSOR_A);
    assert(field);
    field[15] = '9';
    assert(tlm_handle_ack_json(&q, altered) == TLM_ACK_IGNORED);
    assert(q.count == 1);
    assert(tlm_handle_ack_json(&q, ack) == TLM_ACK_REMOVED);
    uint8_t entropy[16] = {0};
    assert(tlm_node_init(&node, "sample-node-a", "v\"1\\test", entropy));
    assert(tlm_queue_init(&q, 1));
    assert(tlm_enqueue(&q, &node, SENSOR_A, TLM_OK, true, 250,
                       TLM_UNSYNCED, NULL, 100, 1000, true, &r));
    char json[TLM_JSON_SIZE];
    assert(tlm_measurement_json(&r, false, json));
    assert(strstr(json, "\"firmware_version\":\"v\\\"1\\\\test\"") != NULL);
    puts("PASS: malformed ACK rejection and JSON escaping");
}

int main(void)
{
    test_identity_and_json();
    test_ack_and_sequence();
    test_buffer_and_status();
    test_ack_rejection_and_escaping();
    puts("PASS: all host tests");
    return 0;
}
