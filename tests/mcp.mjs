import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {createServer} from 'node:net';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

// MCP boundary only: deterministic native-protocol fixture; no App, TCC or desktop actions.
const require=createRequire(process.env.MACUSE_SDK_PACKAGE??process.env.NATIVE_CU_SDK_PACKAGE??new URL('../bridge/server.mjs',import.meta.url));
const {Client}=require('@modelcontextprotocol/sdk/client/index.js');
const {StdioClientTransport}=require('@modelcontextprotocol/sdk/client/stdio.js');
const dir=mkdtempSync(join(tmpdir(),'cu-mcp-'));
const socket=join(dir,'fixture.sock'), requests=[], peers=new Set();
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWVQAAAAASUVORK5CYII=','base64').toString('base64');
const fixture=createServer(peer=>{
 peers.add(peer);peer.on('close',()=>peers.delete(peer));peer.on('error',()=>{});
 let buffer=Buffer.alloc(0);
 peer.on('data',chunk=>{
  buffer=Buffer.concat([buffer,chunk]);
  while(buffer.length>=4){
   const size=buffer.readUInt32LE();if(buffer.length<size+4)return;
   const request=JSON.parse(buffer.subarray(4,size+4));buffer=buffer.subarray(size+4);requests.push(request);
   const {name,arguments:args}=request.params;
   let result;
   if(name==='check_permissions')result={accessibility:true,screen_recording:true};
   else if(name==='get_app_state')result={app:args.app,snapshot_id:'fixture-snapshot',state:'fixture AX state'};
   else if(name==='get_screenshot')result={data:png,mimeType:'image/png',width:1,height:1,snapshot_id:args.snapshot_id};
   else result={isError:true,code:'stale_snapshot',message:'fixture stale snapshot'};
   const body=Buffer.from(JSON.stringify({jsonrpc:'2.0',id:request.id,result}));
   const header=Buffer.alloc(4);header.writeUInt32LE(body.length);
   // Split the response header to exercise stream framing through the real bridge.
   peer.write(header.subarray(0,2));setImmediate(()=>peer.write(Buffer.concat([header.subarray(2),body])));
  }
 });
});
await new Promise((resolve,reject)=>{fixture.once('error',reject);fixture.listen(socket,resolve);});
let client;
async function connect(){
 const env=Object.fromEntries(Object.entries(process.env).filter(([,v])=>typeof v==='string'));
 env.MACUSE_SOCKET=socket;env.MACUSE_SESSION='mcp-test-session';
 const transport=new StdioClientTransport({command:process.execPath,args:[fileURLToPath(new URL('../bridge/server.mjs',import.meta.url))],env});
 client=new Client({name:'mcp-boundary-test',version:'1'});await client.connect(transport);
}
try{
 await connect();
 const {tools}=await client.listTools();
 assert.deepEqual(tools.map(t=>t.name).sort(),['check_permissions','list_apps','list_displays','get_app_state','get_screenshot','get_display_screenshot','click','set_value','type_text','press_key','end_session'].sort());
 assert.deepEqual(tools.find(t=>t.name==='get_screenshot').inputSchema.required,['app','snapshot_id']);
 console.log('PASS MCP initialization and tool schemas');
 const permissions=await client.callTool({name:'check_permissions',arguments:{}});
 assert.equal(permissions.isError,false);assert.deepEqual(JSON.parse(permissions.content[0].text),{accessibility:true,screen_recording:true});
 const args={app:'fixture.app'};
 const state=await client.callTool({name:'get_app_state',arguments:args});
 assert.equal(JSON.parse(state.content[0].text).snapshot_id,'fixture-snapshot');
 assert.deepEqual(requests.at(-1).params,{session_id:'mcp-test-session',name:'get_app_state',arguments:args});
 console.log('PASS MCP argument/session forwarding and text results');
 const image=await client.callTool({name:'get_screenshot',arguments:{app:'fixture.app',snapshot_id:'fixture-snapshot'}});
 assert.deepEqual(image.content.find(c=>c.type==='image'),{type:'image',data:png,mimeType:'image/png'});
 const metadata=JSON.parse(image.content.find(c=>c.type==='text').text);assert.equal(metadata.width,1);assert.equal(metadata.data,undefined);
 console.log('PASS MCP PNG content and metadata conversion');
 const failure=await client.callTool({name:'press_key',arguments:{app:'fixture.app',snapshot_id:'old',key:'Return'}});
 assert.equal(failure.isError,true);assert.equal(JSON.parse(failure.content[0].text).code,'stale_snapshot');
 const before=requests.length;
 for(const params of [{name:'unknown',arguments:{}},{name:'get_app_state',arguments:{}},{name:'check_permissions',arguments:{unexpected:true}}])assert.equal((await client.callTool(params)).isError,true);
 assert.equal(requests.length,before);
 console.log('PASS MCP native errors and invalid-call rejection');
 await client.close();client=undefined;
 assert.equal(fixture.listening,true);await connect();
 assert.equal((await client.callTool({name:'check_permissions',arguments:{}})).isError,false);
 console.log('PASS MCP disconnect/reconnect leaves external service available');
}finally{
 await client?.close();for(const peer of peers)peer.destroy();
 await new Promise(resolve=>fixture.close(resolve));rmSync(dir,{recursive:true,force:true});
}
