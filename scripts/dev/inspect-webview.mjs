// Inspect only the explicitly started development WebView2 debugging endpoint.
import { writeFile } from "node:fs/promises";
const [port, output] = process.argv.slice(2);
const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = pages.find(p => p.type === "page" && /tauri\.localhost|localhost|tauri:\/\//.test(p.url));
if (!page) throw new Error("No development workbench page found");
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});
let sequence = 0;
const pending = new Map();
socket.addEventListener("message", event => {
  const message = JSON.parse(event.data);
  if (message.id) {
    const callback = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) callback?.reject(new Error(JSON.stringify(message.error)));
    else callback?.resolve(message.result);
  }
});
function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
try {
  const result = await call("Runtime.evaluate", { expression: "JSON.stringify({title:document.title,ready:document.readyState,text:document.body.innerText,controls:document.querySelectorAll('button,input,textarea').length})", returnByValue: true });
  const body = JSON.parse(result.result.value);
  await writeFile(output + ".json", JSON.stringify(body, null, 2));
  const screenshot = await call("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  await writeFile(output + ".png", Buffer.from(screenshot.data, "base64"));
  if (body.controls === 0 || body.text.length < 40) throw new Error("Window exists but rendered application UI is empty");
  console.log(JSON.stringify({ title: body.title, ready: body.ready, controls: body.controls, textLength: body.text.length }));
} finally { socket.close(); }
