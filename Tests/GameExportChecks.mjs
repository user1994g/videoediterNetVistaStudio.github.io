import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=process.argv[2];
for(const dimension of ['2D','3D']) {
  const folder=`${root}/${dimension}-js`, project=JSON.parse(await readFile(`${folder}/game.json`)), expected=JSON.parse(await readFile(`${folder}/expected.json`));
  const {GameRuntime}=await import(pathToFileURL(`${folder}/runtime.mjs`)); const runtime=new GameRuntime(project);
  for(const keys of expected.frames) runtime.step(new Set(keys),1/60);
  assert(Math.abs(runtime.score-expected.score)<1e-8);assert.deepEqual([...runtime.destroyed].sort(),expected.destroyed);
  for(let i=0;i<runtime.objects.length;i++) for(const key of ['x','y','z','size','rotation','opacity','visible']) {
    const a=runtime.objects[i][key],b=expected.objects[i][key];assert(typeof a==='number'?Math.abs(a-b)<1e-8:a===b,`${dimension} ${key}`);
  }
  console.log(`PASS: ${dimension} JavaScript export matches native runtime over 180 frames`);
}
