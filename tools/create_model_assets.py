"""Build the editable, original vector puppet example; no third-party artwork."""
from pathlib import Path

root = Path(__file__).resolve().parents[1] / 'resources/character_models/ForgePuppet'
root.mkdir(parents=True, exist_ok=True)
body = '''<g stroke="#202c38" stroke-width="5" stroke-linejoin="round">
<ellipse cx="120" cy="306" rx="72" ry="10" fill="#142b36" opacity=".25" stroke="none"/>
<path d="M82 224 70 295 108 295 118 235M130 235 134 295 171 295 157 220" fill="#825c45"/>
<path d="M68 286 64 305 111 305 109 288M132 288 134 305 182 305 169 285" fill="#364c5e"/>
<path d="M65 121 43 185 60 231 79 218 65 180 88 146M169 125 189 172 180 216 158 212 166 174 145 148" fill="#bf9061"/>
<circle cx="57" cy="184" r="13" fill="#efc873"/><circle cx="177" cy="175" r="13" fill="#efc873"/>
<path d="M76 115 162 115 177 225 62 225Z" fill="#397b81"/>
<path d="M83 132 153 132 150 199 90 199Z" fill="#243e50"/>
<path d="M62 222 177 222 177 237 62 237Z" fill="#d8aa64"/>
<circle cx="120" cy="169" r="25" fill="#d8aa64"/><circle cx="120" cy="169" r="15" fill="#94ffde"/>
<path d="M87 24 153 24 169 57 161 105 79 105 71 57Z" fill="#cfa476"/>
<path d="M79 56 161 56 157 85 83 85Z" fill="#243e50"/>
<path d="M91 70h18m22 0h18" stroke="#94ffde" stroke-width="7"/>
<path d="M104 95h32" stroke-width="3"/>
<path d="M76 18 158 18 169 39 69 39Z" fill="#397b81"/>
<path d="M120 18V5" stroke="#d8aa64"/>
<path d="M148 112 180 116 164 154 124 121" fill="#de9e57"/>
</g>'''

def svg(name, width, height, content):
    (root/name).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">{content}</svg>\n', encoding='utf-8')

svg('puppet.svg', 240, 320, body)
svg('icon.svg', 128, 128, '<circle cx="64" cy="64" r="61" fill="#203c50" stroke="#e4b772" stroke-width="5"/><g transform="translate(-39 4) scale(.85)">'+body+'</g>')
svg('select.svg', 132, 195, '<rect x="3" y="3" width="126" height="189" rx="18" fill="#203c50" stroke="#e4b772" stroke-width="5"/><g transform="translate(0 10) scale(.55)">'+body+'</g>')
svg('background.svg', 1920, 900, '<rect width="1920" height="900" fill="#132d3b"/><circle cx="1400" cy="420" r="320" fill="#244d56"/><circle cx="1400" cy="420" r="282" fill="none" stroke="#a57f4e" stroke-width="4"/><g transform="translate(1136 80) scale(2.2)">'+body+'</g>')

states = {
    'idle': (2.0, True, [(0,0), (0,-5), (0,0)], [0,0,0], ['Color(1, 1, 1, 1)']*3),
    'attack': (.4, False, [(0,0), (42,-4), (0,0)], [0,.12,0], ['Color(1, 1, 1, 1)']*3),
    'cast': (.55, False, [(0,0), (0,-18), (0,0)], [0,-.05,0], ['Color(1, 1, 1, 1)', 'Color(1.5, 1.6, 1.3, 1)', 'Color(1, 1, 1, 1)']),
    'hit': (.3, False, [(0,0), (-20,0), (0,0)], [0,-.08,0], ['Color(1, 1, 1, 1)', 'Color(1.8, 0.6, 0.6, 1)', 'Color(1, 1, 1, 1)']),
    'dead': (.7, False, [(0,0), (-10,60), (-20,100)], [0,-.4,-1.35], ['Color(1, 1, 1, 1)', 'Color(0.6, 0.6, 0.6, 1)', 'Color(0.4, 0.4, 0.4, 0.5)']),
}
parts = ['[gd_scene load_steps=9 format=3]', '[ext_resource type="Texture2D" path="res://puppet.svg" id="1"]']
for name, (length, loop, positions, rotations, colors) in states.items():
    parts.append(f'[sub_resource type="Animation" id="Anim_{name}"]\nresource_name = "{name}"\nlength = {length}\nloop_mode = {int(loop)}')
    for track, (prop, values) in enumerate([
        ('position', [f'Vector2({x}, {y})' for x,y in positions]),
        ('rotation', [str(float(x)) for x in rotations]), ('modulate', colors)]):
        parts.append(f'''tracks/{track}/type = "value"
tracks/{track}/path = NodePath("Visuals:{prop}")
tracks/{track}/interp = 1
tracks/{track}/enabled = true
tracks/{track}/keys = {{
"times": PackedFloat32Array(0, {length/2}, {length}),
"transitions": PackedFloat32Array(1, 1, 1),
"update": 0,
"values": [{', '.join(values)}]
}}''')
parts.append('[sub_resource type="AnimationLibrary" id="Library"]\n_data = {\n'+',\n'.join(f'&"{n}": SubResource("Anim_{n}")' for n in states)+'\n}')
parts.append('''[node name="ForgePuppet" type="Node2D"]

[node name="Visuals" type="Node2D" parent="."]
unique_name_in_owner = true

[node name="Body" type="Sprite2D" parent="Visuals"]
position = Vector2(0, -160)
texture = ExtResource("1")

[node name="Bounds" type="Control" parent="."]
unique_name_in_owner = true
offset_left = -100.0
offset_top = -310.0
offset_right = 100.0
mouse_filter = 2

[node name="CenterPos" type="Marker2D" parent="."]
unique_name_in_owner = true
position = Vector2(0, -160)

[node name="IntentPos" type="Marker2D" parent="."]
unique_name_in_owner = true
position = Vector2(0, -360)

[node name="OrbPos" type="Marker2D" parent="."]
unique_name_in_owner = true
position = Vector2(-110, -300)

[node name="TalkPos" type="Marker2D" parent="."]
unique_name_in_owner = true
position = Vector2(80, -280)

[node name="AnimationPlayer" type="AnimationPlayer" parent="."]
libraries = {&"": SubResource("Library")}
''')
scene = '\n\n'.join(parts)
(root/'battle.tscn').write_text(scene, encoding='utf-8')
(root/'world.tscn').write_text(scene + '''autoplay = "idle"

[node name="ControlRoot" type="Control" parent="."]
mouse_filter = 2

[node name="Hitbox" type="Control" parent="ControlRoot"]
unique_name_in_owner = true
offset_left = -110.0
offset_top = -320.0
offset_right = 110.0
focus_mode = 2

[node name="SelectionReticle" type="Control" parent="ControlRoot"]
unique_name_in_owner = true
offset_left = -125.0
offset_top = -335.0
offset_right = 125.0
offset_bottom = 15.0
mouse_filter = 2

[node name="ThoughtBubbleLeft" type="Control" parent="ControlRoot"]
unique_name_in_owner = true
offset_left = -110.0
offset_right = -110.0
offset_top = -280.0
offset_bottom = -280.0
mouse_filter = 2

[node name="ThoughtBubbleRight" type="Control" parent="ControlRoot"]
unique_name_in_owner = true
offset_left = 110.0
offset_right = 110.0
offset_top = -280.0
offset_bottom = -280.0
mouse_filter = 2
''', encoding='utf-8')
(root/'project.godot').write_text('config_version=5\n[application]\nconfig/name="Forge Puppet Model"\nrun/main_scene="res://battle.tscn"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding='utf-8')
print(root)
