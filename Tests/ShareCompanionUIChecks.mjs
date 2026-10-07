// Pure client unit checks: no real browser, credentials, user data or network.
// First run ShareCollaborationChecks with an output directory, then pass its
// generated companion.js as the argument to this Node test.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(process.argv[2], 'utf8');
const nodes = new Map();
class Element {
  constructor(tag = 'div') { this.tagName = tag; this.children = []; this.value = ''; this.disabled = false; this.dataset = {}; this.classes = new Set(); this.classList = {add: c => this.classes.add(c), remove: c => this.classes.delete(c), toggle: (c, yes) => yes ? this.classes.add(c) : this.classes.delete(c)}; }
  set id(id) { this._id = id; nodes.set(id, this); }
  get id() { return this._id; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = items; }
  setAttribute(k, v) { this[k] = v; }
}
const ids = ['notice','connection','deviceName','project','team','sceneSelect','items','listHeading','review','controls','time','settingsHeading','primitive','limits','apply','delete','add','join','release','revert','previewTime','preview','previewMessage','play','kind'];
ids.forEach(id => { const element = new Element(); element.id = id; });
nodes.get('time').value = '0'; nodes.get('kind').value = 'sphere';
const modes = ['colour','scene','review'].map(mode => { const e = new Element('button'); e.dataset.mode = mode; return e; });
const descendants = element => element.children.flatMap(c => [c, ...descendants(c)]);
const document = {
  hidden: false, hasFocus: () => true,
  getElementById: id => nodes.get(id), createElement: tag => new Element(tag),
  querySelectorAll: selector => selector === '[data-mode]' ? modes : selector === '#controls input' ? descendants(nodes.get('controls')).filter(e => e.tagName === 'input') : []
};
const project = {version:1,projectID:'project',title:'Shared',clips:[{id:'clip',name:'Clip',duration:5,revision:1,editable:true,values:{exposure:0,contrast:1,saturation:1,temperature:6500,tint:0,vibrance:0}}],scenes:[{id:'scene',name:'Scene',revision:1,duration:5,editable:true,objects:[{id:'object',name:'Cube',kind:'cube',revision:1,editable:true,transform:{position:{x:0,y:0,z:0},rotation:{x:0,y:0,z:0},scale:{x:1,y:1,z:1}}}]}],sessions:[]};
let count = 0, conflictNext = false;
const commands = [];
function response(value, status = 200) { return {ok: status===200,status, json: async()=>structuredClone(value),text:async()=>String(value),blob:async()=>({})}; }
const fetch = async(path, options={}) => {
  if(path === '/api/project') return response(project);
  if(path.startsWith('/preview.jpg')) return response({});
  assert.equal(path, '/api/command');
  assert.equal(options.headers['X-NetVista-CSRF'], 'test-csrf');
  const command = JSON.parse(options.body); commands.push(command);
  assert.equal(command.projectID, 'project');
  if(command.kind !== 'join') assert.equal(command.domain, undefined, 'Mutation schema must omit domain');
  let status = 'ok', sessionID;
  if(command.kind === 'join') {
    sessionID='session'+(++count); project.sessions.push({id:sessionID,deviceName:'Test',domain:command.domain});
  } else if(command.kind === 'leave') project.sessions = project.sessions.filter(s=>s.id!==command.sessionID);
  else if(command.kind==='colour') {
    if(conflictNext){status='conflict';conflictNext=false;project.clips[0].values.exposure=.25;project.clips[0].revision++;}
    else { assert.equal(command.expectedRevision, project.clips[0].revision);project.clips[0].values=command.colour;project.clips[0].revision++; }
  } else if(command.kind==='transform') {
    const object=project.scenes[0].objects.find(o=>o.id===command.targetID);assert.equal(command.expectedRevision,object.revision);object.transform=command.transform;object.revision++;
  } else if(command.kind==='addObject') {
    assert.equal(command.expectedRevision,project.scenes[0].revision);project.scenes[0].objects.push({id:command.targetID,name:'Sphere',kind:'sphere',revision:1,editable:true,transform:{position:{x:0,y:0,z:0},rotation:{x:0,y:0,z:0},scale:{x:1,y:1,z:1}}});project.scenes[0].revision++;
  } else if(command.kind==='deleteObject') { project.scenes[0].objects=project.scenes[0].objects.filter(o=>o.id!==command.targetID);project.scenes[0].revision++; }
  return response({status,message:status==='ok'?'Applied':'Host changed the target',sessionID,snapshot:project});
};
const context = vm.createContext({document,window:{addEventListener(){}},navigator:{userAgent:'iPad'},fetch,AbortController,setTimeout,clearTimeout,setInterval(){},URL:{createObjectURL:()=> 'blob:test',revokeObjectURL(){}},confirm:()=>true,console,Math,JSON,Number,Error,String,encodeURIComponent});
vm.runInContext(source,context);
const settle = async()=>{for(let i=0;i<12;i++)await new Promise(resolve=>setImmediate(resolve));};
await settle();
assert.equal(nodes.get('project').textContent,'Shared');
assert.equal(nodes.get('field-exposure').disabled,true);
await nodes.get('join').onclick();await settle();
assert.equal(nodes.get('field-exposure').disabled,false);
const exposure=nodes.get('field-exposure');exposure.value='1.5';exposure.oninput();exposure.onchange();await settle();
assert.equal(project.clips[0].values.exposure,1.5);
assert.equal(nodes.get('field-exposure').value,1.5);
conflictNext=true;
const stale=nodes.get('field-exposure');stale.value='2';stale.oninput();stale.onchange();await settle();
assert.equal(project.clips[0].values.exposure,.25);
assert.equal(nodes.get('field-exposure').value,.25, 'Stale browser draft must reload host values');
assert.equal(nodes.get('notice').classes.has('error'),true);
await modes[1].onclick();await settle();
await nodes.get('join').onclick();await settle();
const x=nodes.get('field-position-x');x.value='4';x.oninput();x.onchange();await settle();
assert.equal(project.scenes[0].objects[0].transform.position.x,4);
await nodes.get('add').onclick();await settle();assert.equal(project.scenes[0].objects.length,2);
await nodes.get('delete').onclick();await settle();assert.equal(project.scenes[0].objects.length,1);
await nodes.get('release').onclick();await settle();assert.equal(project.sessions.length,0);
assert.equal(nodes.get('apply').disabled,true);
console.log('PASS: companion client join/grade commit/conflict reload, workspace switch/release, 3D transform/add/delete, wire-schema compatibility and disabled controls');
