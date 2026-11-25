#ifndef MEDIA_REMOTE_ADAPTER_H
#define MEDIA_REMOTE_ADAPTER_H

// Entry points shaped like perl XSUBs (see adapter.m). Both arguments are ignored.
void kramaisland_mra_stream(void *interp, void *cv);
void kramaisland_mra_get(void *interp, void *cv);
void kramaisland_mra_command(void *interp, void *cv);

#endif
