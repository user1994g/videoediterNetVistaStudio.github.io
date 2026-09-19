import {GameRuntime} from './runtime.mjs';
const hud=document.querySelector('#hud');
try {
  const THREE=await import('three');
  const response=await fetch('./game.json'); if(!response.ok) throw Error('Cannot load game.json');
  const project=await response.json(), is2D=project.dimension==='2D'; document.title=project.name;
  let runtime=new GameRuntime(project);
  const renderer=new THREE.WebGLRenderer({antialias:true}); renderer.setPixelRatio(Math.min(devicePixelRatio,2)); document.body.appendChild(renderer.domElement);
  const scene=new THREE.Scene(); scene.background=new THREE.Color('#171b23');
  const camera=is2D?new THREE.OrthographicCamera(-10.5,10.5,6.5,-6.5,.1,1000):new THREE.PerspectiveCamera(45,1,.1,30000);
  camera.position.set(0,is2D?0:15,is2D?100:17); camera.lookAt(0,0,0);
  scene.add(new THREE.AmbientLight(0xffffff,1.5)); const sun=new THREE.DirectionalLight(0xffffff,2); sun.position.set(-4,12,8); scene.add(sun);
  const loader=new THREE.TextureLoader(), textures=new Map();
  for(const id of new Set(project.objects.map(o=>o.imageID).filter(Boolean))) {
    const asset=project.assets.find(a=>a.id===id); const texture=await loader.loadAsync(asset.path); texture.colorSpace=THREE.SRGBColorSpace; textures.set(id,texture);
  }
  const nodes=new Map();
  for(const obj of project.objects) {
    const flat=is2D||obj.kind==='sprite'; let geometry;
    if(obj.modelID) {
      const mesh=project.meshes[obj.modelID]; geometry=new THREE.BufferGeometry();
      geometry.setAttribute('position',new THREE.Float32BufferAttribute(mesh.positions,3)); geometry.setAttribute('uv',new THREE.Float32BufferAttribute(mesh.uv,2)); geometry.computeVertexNormals();
    } else if(flat) geometry=obj.kind==='coin'?new THREE.CircleGeometry(.5,32):new THREE.PlaneGeometry(1,1);
    else geometry=obj.kind==='coin'?new THREE.SphereGeometry(.5,24,16):new THREE.BoxGeometry(1,1,1);
    const material=new (flat?THREE.MeshBasicMaterial:THREE.MeshLambertMaterial)({color:obj.imageID?0xffffff:obj.kind==='coin'?0xf5c45c:0x589fd8,map:textures.get(obj.imageID),transparent:true,alphaTest:.01,side:THREE.DoubleSide});
    const node=new THREE.Mesh(geometry,material); if(obj.kind==='empty') node.visible=false; scene.add(node); nodes.set(obj.id,node);
  }
  const keys=new Set(), map={ArrowUp:'up',ArrowDown:'down',ArrowLeft:'left',ArrowRight:'right',' ':'space'};
  addEventListener('keydown',e=>{if(e.target instanceof HTMLButtonElement)return;const k=map[e.key]||e.key.toLowerCase();if(['up','down','left','right','space','w','a','s','d','e'].includes(k)){e.preventDefault();keys.add(k);}});
  addEventListener('keyup',e=>keys.delete(map[e.key]||e.key.toLowerCase())); addEventListener('blur',()=>keys.clear());
  document.querySelector('#restart').onclick=e=>{runtime=new GameRuntime(project);keys.clear();e.target.blur();};
  function resize(){const aspect=innerWidth/innerHeight;renderer.setSize(innerWidth,innerHeight);if(is2D){const h=Math.max(13,21/aspect);camera.top=h/2;camera.bottom=-h/2;camera.left=-h*aspect/2;camera.right=h*aspect/2;}else camera.aspect=aspect;camera.updateProjectionMatrix();}
  addEventListener('resize',resize);resize();let previous=performance.now();
  renderer.setAnimationLoop(now=>{const dt=(now-previous)/1000;previous=now;if(!document.hidden)runtime.step(keys,dt);
    runtime.objects.forEach((obj,index)=>{const node=nodes.get(obj.id);node.position.set(obj.x,obj.y,is2D?index*.001:obj.z);node.scale.setScalar(obj.size);node.rotation.set(0,is2D?0:obj.rotation*Math.PI/180,is2D?obj.rotation*Math.PI/180:0);node.material.opacity=obj.opacity;node.visible=obj.visible&&!runtime.destroyed.has(obj.id)&&obj.kind!=='empty';});
    hud.textContent=project.name+'\nScore: '+Number(runtime.score.toFixed(2));renderer.render(scene,camera);
  });
} catch(error) { hud.textContent='Could not start the game.\n'+error.message+'\nSee README.md for setup instructions.'; console.error(error); }
