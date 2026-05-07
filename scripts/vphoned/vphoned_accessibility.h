/*
 * vphoned_accessibility — Accessibility tree query over vsock.
 *
 * Handles accessibility_tree by querying iOS private AXRuntime /
 * AccessibilityUtilities from the guest daemon.  No OCR is involved: returned
 * nodes come from the app accessibility layer and include logical point frames
 * plus screenshot-pixel frames when the host provides screen dimensions.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Returns YES when the private AX classes needed for tree capture are present.
BOOL vp_accessibility_available(void);

/// Handle an accessibility_tree command. Returns a response dict.
NSDictionary *vp_handle_accessibility_command(NSDictionary *msg);
