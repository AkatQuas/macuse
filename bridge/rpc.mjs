import {createConnection} from 'node:net';
import {randomUUID} from 'node:crypto';
export async function rpc(socketPath, method, params, {signal, timeoutMs=30000}={}) {
  if(signal?.aborted) throw signal.reason ?? new Error('Aborted');
  return new Promise((resolve,reject)=>{
    const id=randomUUID(); let buffered=Buffer.alloc(0), done=false;
    const socket=createConnection(socketPath);
    const timer=setTimeout(()=>finish(new Error('MacUse request timed out; an in-flight action may have completed. Read fresh state before retrying input.')),timeoutMs);
    const abort=()=>finish(new Error('Client cancelled; an in-flight native action may still complete. Read fresh state before further input.'));
    function finish(error,result){if(done)return;done=true;clearTimeout(timer);signal?.removeEventListener('abort',abort);socket.destroy();error?reject(error):resolve(result);}
    signal?.addEventListener('abort',abort,{once:true});
    socket.on('error',error=>finish(error));
    socket.on('close',()=>finish(new Error('MacUse closed the connection before responding')));
    socket.on('connect',()=>{const body=Buffer.from(JSON.stringify({jsonrpc:'2.0',id,method,params}));if(body.length>1024*1024)return finish(new Error('Request exceeds 1 MiB'));const header=Buffer.alloc(4);header.writeUInt32LE(body.length);socket.write(Buffer.concat([header,body]));});
    socket.on('data',chunk=>{
      buffered=Buffer.concat([buffered,chunk]);
      if(buffered.length<4)return;
      const length=buffered.readUInt32LE();
      if(length>24*1024*1024)return finish(new Error('Response exceeds 24 MiB'));
      if(buffered.length<length+4)return;
      try{const response=JSON.parse(buffered.subarray(4,4+length));if(response.id!==id)throw new Error('Response ID mismatch');if(response.error)throw new Error(response.error.message);finish(null,response.result);}catch(error){finish(error);}
    });
  });
}
