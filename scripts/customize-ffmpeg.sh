#!/bin/bash

set -eo pipefail
source $(dirname $0)/var.sh

cp -fr $OUTPUT_PATH $OUTPUT_PATH_WV

replace()
{
	if ! grep -qF "$1" "$3"; then
		echo "$3 does not contain expected $1"
		exit 1
	fi
	ESCAPED_FROM=$(printf '%s\n' "$1" | sed -e 's/[]\/$*.^[]/\\&/g');
	ESCAPED_TO=$(printf '%s\n' "$2" | sed -e 's/[\/&]/\\&/g');
	sed -i -e "s/$ESCAPED_FROM/$ESCAPED_TO/g" $3
}

# replacing stdout write script in ffmpeg.js
replace "for(var i=0;i<length;i++){try{output(buffer[offset+i])}catch(e){throw new FS.ErrnoError(29)}}" \
	"let i = length;try{output(buffer, offset, length)}catch(e){throw new FS.ErrnoError(29)}" \
	$OUTPUT_PATH_WV

# replacing tty write script in ffmpeg.js
replace "try{for(var i=0;i<length;i++){stream.tty.ops.put_char(stream.tty,buffer[offset+i])}}" \
	"try{if(Module.tty && Module.tty(stream,buffer,offset,length,pos))var i=length;else for(var i=0;i<length;i++){stream.tty.ops.put_char(stream.tty,buffer[offset+i])}}" \
	$OUTPUT_PATH_WV

# replacing stdin read script in ffmpeg.js
replace "for(var i=0;i<length;i++){var result;try{result=input()}catch(e){throw new FS.ErrnoError(29)}if(result===undefined&&bytesRead===0){throw new FS.ErrnoError(6)}if(result===null||result===undefined)break;bytesRead++;buffer[offset+i]=result}" \
	"if(input===Module.stdin){var result;try{result=input(length)}catch(e){throw new FS.ErrnoError(29)}if(result===undefined){throw new FS.ErrnoError(6)}bytesRead = result.byteLength;buffer.set(result, offset);}else{for(var i=0;i<length;i++){var result;try{result=input()}catch(e){throw new FS.ErrnoError(29)}if(result===undefined&&bytesRead===0){throw new FS.ErrnoError(6)}if(result===null||result===undefined)break;bytesRead++;buffer[offset+i]=result}}" \
	$OUTPUT_PATH_WV

# Reusable-runtime patch (4th; paired with EXIT_RUNTIME=0 in build-ffmpeg.sh):
# callMain() must keep the runtime fully alive so it can be called repeatedly.
#   - Push a runtime keepalive token for every run: while it is held, _proc_exit()
#     (reached when C code calls exit(status)) records EXITSTATUS without
#     PThread.terminateAllThreads() / Module.onExit / ABORT=true, so the em-pthread
#     pool survives between runs. The token is never popped: keepRuntimeAlive()
#     stays true from the first run on (ffmpeg's main() returns normally, so the
#     normal path never reaches proc_exit anyway).
#   - Skip the exitJS(ret, true) tail so the normal return path does not touch the
#     exit machinery at all; callMain() returns the value main() returned.
#   - The catch keeps emscripten's handleException(): an ExitStatus thrown by
#     quit_() (C exit() path, unwound through wasm) makes callMain() return
#     EXITSTATUS; real crashes are still re-thrown by handleException().
# PROXY_TO_PTHREAD build semantics: entryFunction is __emscripten_proxy_main,
# which spawns a fresh detached "Application main thread" em-pthread per call
# and returns 0 immediately, so callMain() returns without blocking and the
# hosting worker's event loop stays free to service the scheduler's sync-proxied
# nested spawns (see doc/reusable-runtime-build.md Addendum 3 for why this flag
# is mandatory). The push is redundant with the generated PROXY_TO_PTHREAD push
# in callMain (two tokens per run; only one is popped by exitOnMainThread, so
# runtimeKeepaliveCounter grows by 1 per run — harmless) but is kept unchanged
# because a vendored-pin test greps this exact string.
# Completion signal for callers: Module.onExit(status) with the REAL exit code,
# fired by the 5th patch below on every run's exit path.
replace "try{var ret=entryFunction(argc,argv);exitJS(ret,true);return ret}catch(e){return handleException(e)}" \
	"try{runtimeKeepalivePush();var ret=entryFunction(argc,argv);return ret}catch(e){return handleException(e)}" \
	$OUTPUT_PATH_WV

# Persistent-runtime core (5th patch; the heart of the reusable proxied-main
# design). Generated _proc_exit() (pthread build):
#   function _proc_exit(code){if(ENVIRONMENT_IS_PTHREAD)return proxyToMainThread(0,0,1,code);EXITSTATUS=code;if(!keepRuntimeAlive()){PThread.terminateAllThreads();Module["onExit"]?.(code);ABORT=true}quit_(code,new ExitStatus(code))}
# In the original EXIT_RUNTIME=1 build this branch tore the whole runtime down
# (terminateAllThreads + ABORT + quit_ throwing ExitStatus), which is why the
# player allocated a fresh module+memory per ffmpeg run. Patched semantics:
#   - The exit path fires Module["onExit"]?.(code) with the REAL exit code
#     (0 success, 1 ffmpeg error) and RETURNS — WITHOUT terminateAllThreads,
#     ABORT=true, or quit_/exit_: the runtime NEVER tears down, no ExitStatus
#     is thrown into the proxied-call context, and the next
#     __emscripten_proxy_main can run main again.
#   - Recycles the finished proxied-main em-pthread: _proc_exit runs on the
#     module-hosting thread while executing the ASYNC-proxied exitOnMainThread
#     of the thread that called exit(), and PThread.currentProxiedOperationCallerThread
#     is that (now finished) thread. cleanupThread() returns its Worker to
#     PThread.unusedWorkers and frees its pthread struct + stack block
#     (~5 MB of linear memory per run) — without this, every ffmpeg run leaks
#     one Worker and one 5 MB thread block. The variable is zeroed first so the
#     framework's own reset in _emscripten_receive_on_main_thread_js never
#     observes a stale (freed) pointer.
#   - abort()/wasm-trap paths still throw/reject normally (module-drop
#     territory, not exit): this branch is only reached via the exit() path.
replace "EXITSTATUS=code;if(!keepRuntimeAlive()){PThread.terminateAllThreads();Module[\"onExit\"]?.(code);ABORT=true}quit_(code,new ExitStatus(code))" \
	"EXITSTATUS=code;Module[\"onExit\"]?.(code);var wvExpired=PThread.currentProxiedOperationCallerThread;if(wvExpired){PThread.currentProxiedOperationCallerThread=0;cleanupThread(wvExpired)}return" \
	$OUTPUT_PATH_WV