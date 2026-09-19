// NetVista event/action interpreter. Keep semantics aligned with GameRuntime.swift.
export class GameRuntime {
  constructor(project) {
    this.objects = JSON.parse(JSON.stringify(project.objects)); this.dimension = project.dimension;
    this.variables = Object.create(null); this.animations = {}; this.animationSpeeds = {}; this.previousKeys = new Set();
    this.score = 0; this.elapsed = 0; this.started = false; this.destroyed = new Set(); this.contacts = new Set();
  }
  overlaps(a,b) { const r=(a.size+b.size)/2; return Math.abs(a.x-b.x)<r && Math.abs(a.y-b.y)<r && (this.dimension==='2D'||Math.abs(a.z-b.z)<r); }
  move(o,dx,dy,dz) {
    for(const [axis,delta] of [['x',dx],['y',dy],['z',dz]]) {
      if(axis==='z'&&this.dimension==='2D') continue;
      const next={...o,[axis]:Math.max(-10000,Math.min(10000,o[axis]+delta))};
      if(!this.objects.some(b=>b.id!==o.id&&b.solid&&b.visible&&!this.destroyed.has(b.id)&&this.overlaps(next,b))) o[axis]=next[axis];
    }
  }
  step(keys,seconds) {
    const dt=Number.isFinite(seconds)?Math.max(0,Math.min(.05,seconds)):0, old=this.elapsed;
    this.elapsed+=dt; const contacts=new Set();
    for(const owner of this.objects) {
      if(this.destroyed.has(owner.id)) continue;
      for(const rule of owner.rules) {
        if(this.destroyed.has(owner.id)) break;
        if(!rule.enabled) continue;
        const token=owner.id+rule.id; let fire=false;
        switch(rule.event) {
          case 'start': fire=!this.started; break;
          case 'update': fire=true; break;
          case 'keyHeld': fire=keys.has(rule.key); break;
          case 'keyPressed': fire=keys.has(rule.key)&&!this.previousKeys.has(rule.key); break;
          case 'timer': fire=Math.floor(this.elapsed/rule.interval)>Math.floor(old/rule.interval); break;
          case 'touch': {
            const other=this.objects.find(o=>o.id===rule.otherID);
            const touching=other&&other.id!==owner.id&&!this.destroyed.has(other.id)&&owner.visible&&other.visible&&this.overlaps(owner,other);
            if(touching) contacts.add(token); fire=touching&&!this.contacts.has(token); break;
          }
        }
        if(!fire) continue;
        const graph=rule.graph;
        const pending=graph?graph.wires.filter(w=>w.from===rule.id).map(w=>w.to):rule.actions.map(a=>a.id), visited=new Set();
        while(pending.length) {
          const id=pending.shift(); if(visited.has(id))continue; visited.add(id);
          const a=rule.actions.find(a=>a.id===id); if(!a)continue; let branch=null;
          const o=this.objects.find(o=>o.id===(a.targetID??owner.id)); if(!o||this.destroyed.has(o.id)) continue;
          switch(a.kind) {
            case 'keyboard': {
              const x=Number(keys.has('d')||keys.has('right'))-Number(keys.has('a')||keys.has('left'));
              const y=Number(keys.has('w')||keys.has('up'))-Number(keys.has('s')||keys.has('down'));
              const d=a.value*dt/Math.max(1,Math.hypot(x,y)); this.move(o,x*d,this.dimension==='2D'?y*d:0,this.dimension==='3D'?-y*d:0); break;
            }
            case 'move': this.move(o,a.x*dt,a.y*dt,a.z*dt); break;
            case 'position': o.x=a.x; o.y=a.y; o.z=a.z; break;
            case 'rotate': o.rotation=(o.rotation+a.value*dt)%360; break;
            case 'scale': o.size=Math.max(.01,Math.min(1000,a.value)); break;
            case 'opacity': o.opacity=Math.max(0,Math.min(1,a.value)); break;
            case 'show': o.visible=true; break;
            case 'hide': o.visible=false; break;
            case 'destroy': this.destroyed.add(o.id); break;
            case 'score': this.score+=a.value; break;
            case 'ifKey': branch=a.text==='movement'?['w','a','s','d','up','down','left','right'].some(k=>keys.has(k)):keys.has(a.text??'space'); break;
            case 'ifScore': branch=this.score>=a.value; break;
            case 'ifTouch': branch=o.id!==owner.id&&owner.visible&&o.visible&&this.overlaps(owner,o); break;
            case 'setVariable': this.variables[a.text??'health']=a.value; break;
            case 'addVariable': this.variables[a.text??'health']=(this.variables[a.text??'health']??0)+a.value; break;
            case 'ifVariable': branch=(this.variables[a.text??'health']??0)>=a.value; break;
            case 'walk': this.animations[o.id]='walk'; this.animationSpeeds[o.id]=Math.max(.01,Math.min(10,a.value)); break;
            case 'spriteAnimation': this.animations[o.id]='sprite'; this.animationSpeeds[o.id]=Math.max(.01,Math.min(10,a.value)); break;
            case 'stopAnimation': delete this.animations[o.id]; delete this.animationSpeeds[o.id]; break;
          }
          if(graph){const port=branch===null?'next':branch?'yes':'no'; pending.unshift(...graph.wires.filter(w=>w.from===a.id&&w.port===port).map(w=>w.to));}
        }
      }
    }
    this.contacts=contacts; this.started=true; this.previousKeys=new Set(keys);
  }
}
