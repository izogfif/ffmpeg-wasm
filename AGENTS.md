To test in Chrome use MCP:

- Check if Chrome is running by sending an HTTP request to http://localhost:9222 and only if the request times out, start Chrome.
- To start Chrome launch it in Powershell in background with command `b:\browsers\GoogleChromePortable149-russia\GoogleChromePortable.exe` without arguments, it automatically listens at port 9222. 
- To check that dev server is running, send an HTTP request to http://localhost:8080/index.html and only if you get no response start the dev server (see below).
- To start dev server, run Powershell in background with command `node serve.js`.
- To upload a file in `<input type="file">` you might first need to copy the file to a temp folder.
- Test video file is `sample-video.mkv`.
- If you want to restart dev server, you might need to kill `node` executable. You must only kill the executable that listens on port 8080.
- If you encounter issues with launching dev server or Chrome or accessig it via MCP, you must stop and warn the user. Do not attempt to use MSEdge, Firefox or other browsers.
- If you need to add some command-line flags to Chrome, tell that to the user. Do not attempt to launch Chrome with those flags. User will add them to Chrome's launch configuration and restart Chrome for you.
- Do not use `start` command to launch applications, this command hangs on this computer.