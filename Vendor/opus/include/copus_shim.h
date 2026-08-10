/* Pager's shim over libopus's variadic *_ctl API, which Swift cannot call.
 * This header and shim/copus_shim.c are the only non-upstream files in
 * Vendor/opus (opus-1.4, https://opus-codec.org, BSD — see COPYING). */
#ifndef COPUS_SHIM_H
#define COPUS_SHIM_H

#include "opus.h"

int copus_encoder_set_bitrate(OpusEncoder *enc, opus_int32 bitrate);
int copus_encoder_set_complexity(OpusEncoder *enc, opus_int32 complexity);

#endif
