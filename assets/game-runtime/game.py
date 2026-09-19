"""Editable native Python game. Install requirements.txt, then run python game.py."""
import json
import math
from pathlib import Path
from panda3d.core import (Geom, GeomNode, GeomTriangles, GeomVertexData, GeomVertexFormat,
                         GeomVertexWriter, OrthographicLens, TransparencyAttrib, WindowProperties,
                         AmbientLight, DirectionalLight, Vec3, Filename, ClockObject)
from direct.showbase.ShowBase import ShowBase
from direct.gui.OnscreenText import OnscreenText
from engine import GameRuntime

ROOT = Path(__file__).resolve().parent


def geometry(obj, project):
    # Coordinates are converted from Y-up to Panda's Z-up once, at the boundary.
    flat = project['dimension'] == '2D' or obj['kind'] == 'sprite'
    if obj.get('modelID'):
        mesh = project['meshes'][obj['modelID']]
        points = [mesh['positions'][i:i+3] for i in range(0, len(mesh['positions']), 3)]
        uv = [mesh['uv'][i:i+2] for i in range(0, len(mesh['uv']), 2)]
    else:
        points, uv = [], []
        if obj['kind'] == 'coin':
            # Flat disc in 2D, latitude/longitude sphere in 3D.
            for row in range(1 if flat else 16):
                for col in range(32):
                    if flat:
                        for angle in [None, col*math.tau/32, (col+1)*math.tau/32]:
                            p = [0,0,0] if angle is None else [.5*math.cos(angle),.5*math.sin(angle),0]
                            points.append(p); uv.append([p[0]+.5,p[1]+.5])
                    else:
                        for a,b in [(row,col),(row+1,col),(row+1,col+1),(row,col),(row+1,col+1),(row,col+1)]:
                            t,p = a*math.pi/16,b*math.tau/32
                            points.append([.5*math.sin(t)*math.cos(p),.5*math.cos(t),.5*math.sin(t)*math.sin(p)]); uv.append([b/32,a/16])
        else:
            faces = [[[-.5,-.5,0],[.5,-.5,0],[.5,.5,0],[-.5,.5,0]]]
            if not flat:
                faces = [[[-.5,-.5,.5],[.5,-.5,.5],[.5,.5,.5],[-.5,.5,.5]],
                         [[.5,-.5,-.5],[-.5,-.5,-.5],[-.5,.5,-.5],[.5,.5,-.5]],
                         [[-.5,-.5,-.5],[-.5,-.5,.5],[-.5,.5,.5],[-.5,.5,-.5]],
                         [[.5,-.5,.5],[.5,-.5,-.5],[.5,.5,-.5],[.5,.5,.5]],
                         [[-.5,.5,.5],[.5,.5,.5],[.5,.5,-.5],[-.5,.5,-.5]],
                         [[-.5,-.5,-.5],[.5,-.5,-.5],[.5,-.5,.5],[-.5,-.5,.5]]]
            for face in faces:
                for i in [0,1,2,0,2,3]:
                    points.append(face[i]); uv.append([[0,0],[1,0],[1,1],[0,1]][i])
    data = GeomVertexData('mesh', GeomVertexFormat.getV3n3t2(), Geom.UHStatic)
    data.setNumRows(len(points)); vertex = GeomVertexWriter(data,'vertex'); normal = GeomVertexWriter(data,'normal'); tex = GeomVertexWriter(data,'texcoord')
    primitive = GeomTriangles(Geom.UHStatic)
    for i in range(0,len(points),3):
        tri = [Vec3(p[0],-p[2],p[1]) for p in points[i:i+3]]
        n = (tri[1]-tri[0]).cross(tri[2]-tri[0]); n.normalize()
        for j,p in enumerate(tri):
            vertex.addData3(p); normal.addData3(n); tex.addData2(*uv[i+j])
        primitive.addVertices(i,i+1,i+2); primitive.closePrimitive()
    mesh = Geom(data); mesh.addPrimitive(primitive); node = GeomNode('mesh'); node.addGeom(mesh)
    return node


class Game(ShowBase):
    def __init__(self):
        super().__init__()
        self.disableMouse(); self.setBackgroundColor(.09,.106,.137)
        self.project = json.loads((ROOT/'game.json').read_text(encoding='utf-8'))
        self.runtime = GameRuntime(self.project); self.keys = set(); self.nodes = {}
        self.is2d = self.project['dimension'] == '2D'
        if hasattr(self.win, 'requestProperties'):
            props = WindowProperties(); props.setTitle(self.project['name']); self.win.requestProperties(props)
        if self.is2d:
            lens = OrthographicLens(); lens.setFilmSize(21,13); lens.setNearFar(.1,1000); self.cam.node().setLens(lens); self.camera.setPos(0,-100,0)
        else:
            self.camLens.setFov(45); self.camLens.setNearFar(.1,30000); self.camera.setPos(0,-17,15)
        self.camera.lookAt(0,0,0)
        ambient = AmbientLight('ambient'); ambient.setColor((.5,.5,.5,1)); self.render.setLight(self.render.attachNewNode(ambient))
        sun = DirectionalLight('sun'); sun.setColor((.8,.8,.8,1)); light = self.render.attachNewNode(sun); light.setHpr(-35,-50,0); self.render.setLight(light)
        for obj in self.project['objects']:
            node = self.render.attachNewNode(geometry(obj,self.project)); node.setTwoSided(True); node.setTransparency(TransparencyAttrib.MAlpha)
            if self.is2d or obj['kind'] == 'sprite':
                node.setLightOff()
            if obj.get('imageID'):
                asset = next(a for a in self.project['assets'] if a['id']==obj['imageID'])
                texture = self.loader.loadTexture(Filename.fromOsSpecific(str(ROOT/asset['path'])))
                if not texture:
                    raise RuntimeError('Cannot read texture: '+asset['path'])
                node.setTexture(texture); node.setColor(1,1,1,1)
            else:
                node.setColor(*((.96,.77,.36,1) if obj['kind']=='coin' else (.345,.624,.847,1)))
            self.nodes[obj['id']] = node
        for key in ['w','a','s','d','e','space','up','down','left','right']:
            event = 'arrow_'+key if key in ['up','down','left','right'] else key
            self.accept(event, self.keys.add, [key]); self.accept(event+'-up', self.keys.discard, [key])
        self.accept('escape', self.userExit); self.accept('r', self.restart_game); self.accept('window-event',self.window_changed)
        self.hud = OnscreenText(text='',pos=(-1.25,.9),scale=.045,align=0,fg=(1,1,1,1),mayChange=True)
        self.taskMgr.add(self.tick,'game-update')

    def restart_game(self):
        self.runtime = GameRuntime(self.project); self.keys.clear()

    def window_changed(self, window):
        if not window.getProperties().getForeground():
            self.keys.clear()
        if self.is2d and window.getYSize():
            aspect = window.getXSize()/window.getYSize(); height = max(13,21/aspect)
            self.cam.node().getLens().setFilmSize(height*aspect,height)

    def tick(self, task):
        if not hasattr(self.win, 'getProperties') or self.win.getProperties().getForeground():
            self.runtime.step(self.keys,ClockObject.getGlobalClock().getDt())
        for i,obj in enumerate(self.runtime.objects):
            node = self.nodes[obj['id']]; node.setPos(obj['x'],-i*.001 if self.is2d else -obj['z'],obj['y']); node.setScale(obj['size'])
            node.setHpr(0 if self.is2d else obj['rotation'],0,-obj['rotation'] if self.is2d else 0); node.setAlphaScale(obj['opacity'])
            node.show() if obj['visible'] and obj['id'] not in self.runtime.destroyed and obj['kind']!='empty' else node.hide()
        self.hud.setText(f"{self.project['name']}\nScore: {self.runtime.score:g}\nR: restart | Esc: quit")
        return task.cont


if __name__ == '__main__':
    Game().run()
