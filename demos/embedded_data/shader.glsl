// Simple vertex shader
#version 300 es

in vec3 position;
in vec2 texcoord;

out vec2 v_texcoord;

uniform mat4 modelViewProjection;

void main() {
    gl_Position = modelViewProjection * vec4(position, 1.0);
    v_texcoord = texcoord;
}
