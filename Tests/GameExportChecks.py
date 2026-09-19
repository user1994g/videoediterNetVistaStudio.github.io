"""Run with an export fixture root. Optional --render checks real Panda3D geometry."""
import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace

root = Path(sys.argv[1])
for dimension in ['2D', '3D']:
    folder = root / (dimension+'-python')
    sys.path.insert(0, str(folder))
    from engine import GameRuntime
    project = json.loads((folder/'game.json').read_text())
    expected = json.loads((folder/'expected.json').read_text())
    runtime = GameRuntime(project)
    for keys in expected['frames']:
        runtime.step(set(keys), 1/60)
    assert abs(runtime.score-expected['score']) < 1e-8
    assert sorted(runtime.destroyed) == expected['destroyed']
    for obj, other in zip(runtime.objects, expected['objects']):
        for key in ['x', 'y', 'z', 'size', 'rotation', 'opacity', 'visible']:
            assert abs(obj[key]-other[key]) < 1e-8, (dimension,key)
    print('PASS:',dimension,'Python export matches native runtime over 180 frames')
    if '--render' in sys.argv:
        from panda3d.core import loadPrcFileData, PNMImage
        loadPrcFileData('', 'window-type offscreen\naudio-library-name null\nwin-size 960 600')
        spec = importlib.util.spec_from_file_location('game',folder/'game.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        app = module.Game()
        # Offscreen windows have no foreground property; advance the engine explicitly.
        for _ in range(10):
            app.runtime.step({'d'},1/60)
            app.tick(SimpleNamespace(cont='cont'))
            app.graphicsEngine.renderFrame()
        assert len(app.nodes) == len(project['objects'])
        picture = PNMImage(); assert app.win.getScreenshot(picture)
        picture.write(str(root/(dimension+'-python.png')))
        app.destroy()
        print('PASS:',dimension,'Panda3D scene construction, textures and screenshot')
    sys.path.pop(0)
