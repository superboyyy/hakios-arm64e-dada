/*
 * BlueTool for dada's Qualcomm Bluetooth chip (ganges, the Wi-Fi chip's twin) -- in place of iOS's /usr/sbin/BlueTool,
 * the job com.apple.BlueTool (build.sh BLUETOOL_SHIM=1).
 *
 * bluetoothd asks BlueTool over XPC to bring the chip up before it opens the serial port: a message with
 * kMsgId "RunBuiltinScript" (or "RunExternalScript", "RunCommand") and kMsgArgs { script: "boot" | "init" |
 * "deepsleep", btaddress }. iOS's BlueTool only knows Broadcom's UART chips and Apple's PCIe ones and answers
 * "Unknown platform/chipset/manufacturer combination". Here the kernel has already done the bring-up (hakios_dada_wifi.c
 * bt_hci, boot-arg dadabt=4: firmware download, HCI reset, /dev/uart.bluetooth), so every script succeeds.
 *
 * The answer is what bluetoothd reads (bluetoothd 0x100400858): result (0: done), manufacturer (the Bluetooth SIG
 * company id; 15 = Broadcom, whose vendor commands bluetoothd speaks -- the kernel's port answers those itself) and
 * firmware (a name, logged).
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>

/* in libxpc on iOS too, but marked unavailable in its SDK header */
extern xpc_connection_t listen_on(const char *name, dispatch_queue_t queue, uint64_t flags)
    __asm__("_xpc_connection_create_mach_service");

static void
answer(xpc_object_t message)
{
	const char *id = xpc_dictionary_get_string(message, "kMsgId");
	xpc_object_t args = xpc_dictionary_get_value(message, "kMsgArgs");
	const char *script = args != NULL && xpc_get_type(args) == XPC_TYPE_DICTIONARY ?
	    xpc_dictionary_get_string(args, "script") : NULL;
	xpc_object_t reply = xpc_dictionary_create_reply(message);
	xpc_connection_t peer = xpc_dictionary_get_remote_connection(message);

	fprintf(stderr, "bluetool: %s, script %s: done (the kernel brought the chip up)\n", id ? id : "(no id)",
	    script ? script : "(none)");
	if (reply == NULL || peer == NULL) {
		return;
	}
	xpc_dictionary_set_int64(reply, "result", 0);
	xpc_dictionary_set_int64(reply, "manufacturer", 15);
	xpc_dictionary_set_string(reply, "firmware", "Qualcomm ganges, brought up by the kernel");
	xpc_dictionary_set_string(reply, "output", "");
	xpc_connection_send_message(peer, reply);
	xpc_release(reply);
}

int
main(void)
{
	xpc_connection_t listener = listen_on("com.apple.BlueTool", NULL,
	    XPC_CONNECTION_MACH_SERVICE_LISTENER);

	setvbuf(stderr, NULL, _IOLBF, 0);
	if (listener == NULL) {
		fprintf(stderr, "bluetool: no mach service com.apple.BlueTool\n");
		return 1;
	}
	xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
			return;
		}
		xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t message) {
			if (xpc_get_type(message) == XPC_TYPE_DICTIONARY) {
				answer(message);
			}
		});
		xpc_connection_resume((xpc_connection_t)peer);
	});
	xpc_connection_resume(listener);
	fprintf(stderr, "bluetool: serving com.apple.BlueTool\n");
	dispatch_main();
}
