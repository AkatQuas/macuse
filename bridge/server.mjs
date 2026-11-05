import {createRequire} from 'node:module';
import {randomUUID} from 'node:crypto';
import {rpc} from './rpc.mjs';
// An explicit existing SDK package.json may be selected for offline development.
const require=createRequire(process.env.MACUSE_SDK_PACKAGE ?? process.env.NATIVE_CU_SDK_PACKAGE ?? import.meta.url);
const {Server}=require('@modelcontextprotocol/sdk/server/index.js');
const {StdioServerTransport}=require('@modelcontextprotocol/sdk/server/stdio.js');
const {ListToolsRequestSchema,CallToolRequestSchema}=require('@modelcontextprotocol/sdk/types.js');
const socketPath=process.env.MACUSE_SOCKET ?? process.env.NATIVE_CU_SOCKET;
if(!socketPath)throw new Error('Set MACUSE_SOCKET to the running native service socket');
const session=process.env.MACUSE_SESSION ?? process.env.NATIVE_CU_SESSION ?? randomUUID();
const text={type:'string',minLength:1};
const target={app:{...text,description:'Allowed application bundle identifier.'},snapshot_id:{...text,description:'ID returned by the most recent observation or action in this session.'}};
const definitions=[
 ['check_permissions','Read Accessibility and screen recording permission status.',{},[],true],
 ['list_apps','List running GUI apps and whether this service permits them.',{},[],true],
 ['list_displays','List connected displays with display_id and geometry for get_display_screenshot.',{},[],true],
 ['get_app_state','Select an allowed app and read its focused window accessibility tree. Returns fresh snapshot_id and integer element indices.',{app:text},['app'],true],
 ['get_screenshot','Capture the selected allowlisted app window as PNG. Requires get_app_state. Does not capture the full desktop.',target,['app','snapshot_id'],true],
 ['get_display_screenshot','Capture a full display as PNG (Screen Recording required). Read-only; does not grant clicking outside the allowlist. Use list_displays for display_id.',{display_id:{type:'integer',minimum:0,description:'display_id from list_displays.'}},['display_id'],true],
 ['click','AXPress an element_index, or left-click screenshot pixel x/y after get_screenshot on an allowlisted app window. Coordinate clicks activate the app and move the system pointer. Returns fresh state.',{...target,element_index:{type:'integer',minimum:0},x:{type:'number',minimum:0},y:{type:'number',minimum:0}},['app','snapshot_id'],false],
 ['set_value','Set the AX value of a settable element and return fresh state.',{...target,element_index:{type:'integer',minimum:0},value:{type:'string'}},['app','snapshot_id','element_index','value'],false],
 ['type_text','Type Unicode text into the selected app. Activates the app. Returns fresh state.',{...target,text:{type:'string',maxLength:16000}},['app','snapshot_id','text'],false],
 ['press_key','Send Return, Tab, Space, Escape, Backspace, Delete, arrows or a/c/v/x/z; optional super/cmd/shift/alt/ctrl modifiers joined with +. Activates app and returns fresh state.',{...target,key:text},['app','snapshot_id','key'],false],
 ['end_session','Discard this session snapshot; does not close the target application or stop the service.',{},[],false],
];
const tools=definitions.map(([name,description,properties,required,readOnlyHint])=>({name,description,inputSchema:{type:'object',properties,required,additionalProperties:false},annotations:{readOnlyHint,destructiveHint:!readOnlyHint,openWorldHint:false}}));
const server=new Server({name:'macuse',version:'0.1.0'},{capabilities:{tools:{}},instructions:'MacUse controls allowlisted macOS apps. Start with get_app_state. Each mutation consumes the supplied snapshot and returns fresh state with a new snapshot_id; use the latest ID and element indices. After errors, cancellation or timeout, read fresh state before more input. Sessions persist across bridge restarts only when MACUSE_SESSION is explicitly reused. The native service is independent of this MCP connection. System permissions must be granted by the user.'});
server.setRequestHandler(ListToolsRequestSchema,async()=>({tools}));
server.setRequestHandler(CallToolRequestSchema,async(request,extra)=>{
 try {
  const tool=tools.find(t=>t.name===request.params.name);
  if(!tool)throw new Error('Unknown tool');
  const args=request.params.arguments??{};
  if(Object.keys(args).some(key=>!Object.hasOwn(tool.inputSchema.properties,key)))throw new Error('Unknown argument');
  for(const key of tool.inputSchema.required)if(!Object.hasOwn(args,key))throw new Error(`Missing argument: ${key}`);
  const result=await rpc(socketPath,'tools/call',{session_id:session,name:tool.name,arguments:args},{signal:extra.signal});
  if((tool.name==='get_screenshot'||tool.name==='get_display_screenshot')&&!result.isError){const {data,mimeType,...metadata}=result;return {content:[{type:'text',text:JSON.stringify(metadata)},{type:'image',data,mimeType}]};}
  return {content:[{type:'text',text:JSON.stringify(result)}],isError:!!result.isError};
 }catch(error){return {content:[{type:'text',text:error.message}],isError:true};}
});
await server.connect(new StdioServerTransport());
