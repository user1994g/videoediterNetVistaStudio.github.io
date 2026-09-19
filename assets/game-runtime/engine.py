"""NetVista event/action interpreter; no rendering or third-party dependency."""
from copy import deepcopy
from math import floor, hypot, isfinite, fmod


class GameRuntime:
    def __init__(self, project):
        self.objects = deepcopy(project['objects'])
        self.dimension = project['dimension']
        self.variables, self.animations, self.animationSpeeds, self.previous_keys = {}, {}, {}, set()
        self.score, self.elapsed, self.started = 0, 0, False
        self.destroyed, self.contacts = set(), set()

    def overlaps(self, a, b):
        radius = (a['size'] + b['size']) / 2
        return (abs(a['x']-b['x']) < radius and abs(a['y']-b['y']) < radius
                and (self.dimension == '2D' or abs(a['z']-b['z']) < radius))

    def move(self, obj, dx, dy, dz):
        for axis, delta in [('x', dx), ('y', dy), ('z', dz)]:
            if axis == 'z' and self.dimension == '2D':
                continue
            candidate = dict(obj, **{axis: max(-10000, min(10000, obj[axis]+delta))})
            if not any(b['id'] != obj['id'] and b['solid'] and b['visible']
                       and b['id'] not in self.destroyed and self.overlaps(candidate, b) for b in self.objects):
                obj[axis] = candidate[axis]

    def step(self, keys, seconds):
        dt = max(0, min(.05, seconds)) if isfinite(seconds) else 0
        old = self.elapsed
        self.elapsed += dt
        contacts = set()
        for owner in self.objects:
            if owner['id'] in self.destroyed:
                continue
            for rule in owner['rules']:
                if owner['id'] in self.destroyed:
                    break
                if not rule['enabled']:
                    continue
                event, token, fire = rule['event'], owner['id']+rule['id'], False
                if event == 'start':
                    fire = not self.started
                elif event == 'update':
                    fire = True
                elif event == 'keyPressed':
                    fire = rule['key'] in keys and rule['key'] not in self.previous_keys
                elif event == 'keyHeld':
                    fire = rule['key'] in keys
                elif event == 'timer':
                    fire = floor(self.elapsed/rule['interval']) > floor(old/rule['interval'])
                elif event == 'touch':
                    other = next((o for o in self.objects if o['id'] == rule.get('otherID')), None)
                    touching = (other and other['id'] != owner['id'] and other['id'] not in self.destroyed
                                and owner['visible'] and other['visible'] and self.overlaps(owner, other))
                    if touching:
                        contacts.add(token)
                    fire = touching and token not in self.contacts
                if not fire:
                    continue
                graph = rule.get('graph')
                pending = [w['to'] for w in graph['wires'] if w['from'] == rule['id']] if graph else [a['id'] for a in rule['actions']]
                visited = set()
                while pending:
                    node_id = pending.pop(0)
                    if node_id in visited:
                        continue
                    visited.add(node_id)
                    action = next((a for a in rule['actions'] if a['id'] == node_id), None)
                    if not action:
                        continue
                    branch = None
                    obj = next((o for o in self.objects if o['id'] == (action.get('targetID') or owner['id'])), None)
                    if not obj or obj['id'] in self.destroyed:
                        continue
                    kind, value = action['kind'], action['value']
                    if kind == 'keyboard':
                        x = int('d' in keys or 'right' in keys)-int('a' in keys or 'left' in keys)
                        y = int('w' in keys or 'up' in keys)-int('s' in keys or 'down' in keys)
                        distance = value*dt/max(1, hypot(x, y))
                        self.move(obj, x*distance, y*distance if self.dimension == '2D' else 0,
                                  -y*distance if self.dimension == '3D' else 0)
                    elif kind == 'move':
                        self.move(obj, action['x']*dt, action['y']*dt, action['z']*dt)
                    elif kind == 'position':
                        for axis in ['x', 'y', 'z']:
                            obj[axis] = action[axis]
                    elif kind == 'rotate':
                        obj['rotation'] = fmod(obj['rotation']+value*dt, 360)
                    elif kind == 'scale':
                        obj['size'] = max(.01, min(1000, value))
                    elif kind == 'opacity':
                        obj['opacity'] = max(0, min(1, value))
                    elif kind == 'show':
                        obj['visible'] = True
                    elif kind == 'hide':
                        obj['visible'] = False
                    elif kind == 'destroy':
                        self.destroyed.add(obj['id'])
                    elif kind == 'score':
                        self.score += value
                    elif kind == 'ifKey':
                        branch = bool(keys.intersection({'w','a','s','d','up','down','left','right'})) if action.get('text') == 'movement' else action.get('text', 'space') in keys
                    elif kind == 'ifScore':
                        branch = self.score >= value
                    elif kind == 'ifTouch':
                        branch = obj['id'] != owner['id'] and owner['visible'] and obj['visible'] and self.overlaps(owner, obj)
                    elif kind == 'setVariable':
                        self.variables[action.get('text', 'health')] = value
                    elif kind == 'addVariable':
                        name = action.get('text', 'health')
                        self.variables[name] = self.variables.get(name, 0) + value
                    elif kind == 'ifVariable':
                        branch = self.variables.get(action.get('text', 'health'), 0) >= value
                    elif kind in ('walk', 'spriteAnimation'):
                        self.animations[obj['id']] = 'walk' if kind == 'walk' else 'sprite'
                        self.animationSpeeds[obj['id']] = max(.01, min(10, value))
                    elif kind == 'stopAnimation':
                        self.animations.pop(obj['id'], None)
                        self.animationSpeeds.pop(obj['id'], None)
                    if graph:
                        port = 'next' if branch is None else 'yes' if branch else 'no'
                        pending[0:0] = [w['to'] for w in graph['wires'] if w['from'] == action['id'] and w['port'] == port]
        self.contacts, self.started = contacts, True
        self.previous_keys = set(keys)
