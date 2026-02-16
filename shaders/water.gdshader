shader_type canvas_item;

uniform sampler2D terrain_data : filter_nearest;
global uniform float water_time;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec2 td = texture(terrain_data, UV).rg;
	float terrain_type = td.r * 10.0;
	float shore_dist = td.g * 20.0;

	// Water types: WATER=0, SHALLOW_WATER=1
	if (terrain_type < 1.5) {
		float strength = clamp(1.0 - shore_dist / 15.0, 0.0, 1.0);
		float phase = water_time * 1.5 + shore_dist * 0.4;
		float wave = sin(phase) * 0.04 * strength;
		base.r += wave;
		base.g += wave * 0.5;
		base.b += wave * 1.5;

		// Foam near shore
		if (shore_dist < 3.0 && sin(phase * 2.0) > 0.7) {
			float foam = (3.0 - shore_dist) / 3.0 * 0.3;
			base = mix(base, vec4(1.0), foam);
		}
	}

	COLOR = base;
}
