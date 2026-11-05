import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,chmodSync,existsSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {rpc} from '../bridge/rpc.mjs';
const root=mkdtempSync(join(tmpdir(),'macuse-test-'));chmodSync(root,0o700);
const socket=join(root,'cu.sock');
const child=spawn(resolve('.build/debug/MacUse'),['serve','--socket',socket],{stdio:['ignore','ignore','pipe']});
let log='';child.stderr.on('data',chunk=>log+=chunk);
try {
 for(let i=0;i<100&&!existsSync(socket);i++){if(child.exitCode!==null)throw new Error(log);await new Promise(r=>setTimeout(r,25));}
 assert.equal((await rpc(socket,'ping',{})).serverApiVersion,'MacUse-1');
 const call=(name,args={},session_id='test')=>rpc(socket,'tools/call',{name,arguments:args,session_id});
 const permissions=await call('check_permissions');assert.equal(typeof permissions.accessibility,'boolean');
 assert.equal(typeof permissions.screen_recording,'boolean');
 assert.equal((await call('get_screenshot',{app:'com.apple.calculator',snapshot_id:'missing'})).code,'snapshot_required');
 assert.equal((await call('get_screenshot',{app:'com.apple.calculator',snapshot_id:'missing'},'other')).code,'snapshot_required');
 assert.equal((await call('end_session')).ended,true);
 assert.equal((await call('not_a_tool')).code,'unknown_tool');
 await assert.rejects(rpc(socket,'tools/call',{name:'list_apps',session_id:''}),/session_id/);
 const second=spawn(resolve('.build/debug/MacUse'),['serve','--socket',socket]);
 const status=await new Promise(r=>second.on('exit',r));assert.notEqual(status,0);
 assert.equal((await rpc(socket,'ping',{})).architecture,'arm64');
 // Orphan socket file (e.g. after SIGKILL): new instance should probe, unlink, and serve.
 child.kill('SIGKILL');await new Promise(r=>child.once('exit',r));
 assert.equal(existsSync(socket),true,'SIGKILL leaves the socket path');
 const recovered=spawn(resolve('.build/debug/MacUse'),['serve','--socket',socket],{stdio:['ignore','pipe','pipe']});
 let recoveredLog='';recovered.stderr.on('data',c=>recoveredLog+=c);
 for(let i=0;i<100;i++){
  if(recovered.exitCode!==null)throw new Error(recoveredLog);
  try{assert.equal((await rpc(socket,'ping',{})).serverApiVersion,'MacUse-1');break;}
  catch{await new Promise(r=>setTimeout(r,25));}
 }
 assert.match(recoveredLog,/Removed stale socket/);
 recovered.kill('SIGTERM');await new Promise(r=>recovered.once('exit',r));
 console.log('PASS: framing, reconnects, permission contract, session isolation, unknown tool, malformed session, duplicate service, stale socket recovery');
}finally{
 rmSync(root,{recursive:true,force:true});
}
