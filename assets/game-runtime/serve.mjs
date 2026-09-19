import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root=path.dirname(fileURLToPath(import.meta.url));
const types={'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg'};
const server=http.createServer(async(req,res)=>{
  try {
    const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
    const file=path.resolve(root,'.'+(pathname==='/'?'/index.html':pathname));
    if(!file.startsWith(root+path.sep)) { res.writeHead(403).end(); return; }
    const body=await readFile(file); res.writeHead(200,{'Content-Type':types[path.extname(file)]||'application/octet-stream'}).end(body);
  } catch { res.writeHead(404).end('Not found'); }
});
server.listen(process.env.NETVISTA_GAME_PORT===undefined?8080:Number(process.env.NETVISTA_GAME_PORT),'127.0.0.1',()=>console.log(`Game: http://127.0.0.1:${server.address().port} — Ctrl+C to stop`));
