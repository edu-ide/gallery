#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

char *mail_mcp_rs_embedded_init(const char *db_path);
char *mail_mcp_rs_embedded_list_tools(void);
char *mail_mcp_rs_embedded_list_prompts(const char *locale);
char *mail_mcp_rs_embedded_get_prompt(const char *name, const char *locale);
char *mail_mcp_rs_embedded_call_tool(const char *name, const char *args_json);
void mail_mcp_rs_embedded_free_string(char *ptr);

#ifdef __cplusplus
}
#endif
