#ifndef TC_APP_FFI_H
#define TC_APP_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TcCore TcCore;

TcCore *tc_core_create(const char *config_json);
void tc_core_destroy(TcCore *handle);

char *tc_core_dispatch_json(TcCore *handle, const char *command_json);
char *tc_core_snapshot_json(const TcCore *handle);
char *tc_core_ingest_module_event_json(TcCore *handle, const char *event_json);
char *tc_core_drain_module_commands_json(TcCore *handle);
char *tc_core_last_error_json(void);

void tc_core_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
