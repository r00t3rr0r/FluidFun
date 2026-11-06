function installFluidViscosity(simulation) {
    const fluid = simulation.fluid;
    const gl = simulation.gl;
    simulation.wallpaperViscosity = 0;
    let resources;

    function createResources() {
        function compile(type, source) {
            const shader = gl.createShader(type);
            gl.shaderSource(shader, source);
            gl.compileShader(shader);
            if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
                const message = gl.getShaderInfoLog(shader);
                gl.deleteShader(shader);
                throw new Error(message);
            }
            return shader;
        }
        const vertex = compile(gl.VERTEX_SHADER, `
            attribute vec2 position;
            varying vec2 uv;
            void main() {
                uv = position * 0.5 + 0.5;
                gl_Position = vec4(position, 0.0, 1.0);
            }
        `);
        const fragment = compile(gl.FRAGMENT_SHADER, `
            precision highp float;
            varying vec2 uv;
            uniform sampler2D initialVelocity;
            uniform sampler2D estimate;
            uniform vec2 texel;
            uniform float diffusion;
            void main() {
                vec2 neighbors = texture2D(estimate, uv + vec2(texel.x, 0.0)).xy
                    + texture2D(estimate, uv - vec2(texel.x, 0.0)).xy
                    + texture2D(estimate, uv + vec2(0.0, texel.y)).xy
                    + texture2D(estimate, uv - vec2(0.0, texel.y)).xy;
                vec2 velocity = (texture2D(initialVelocity, uv).xy + diffusion * neighbors)
                    / (1.0 + 4.0 * diffusion);
                gl_FragColor = vec4(velocity, 0.0, 1.0);
            }
        `);
        const program = gl.createProgram();
        gl.attachShader(program, vertex);
        gl.attachShader(program, fragment);
        gl.linkProgram(program);
        gl.deleteShader(vertex);
        gl.deleteShader(fragment);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
        const quad = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, quad);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
        const target = fluid.velocityRenderTarget;
        return {
            program, quad,
            position: gl.getAttribLocation(program, 'position'),
            initial: gl.getUniformLocation(program, 'initialVelocity'),
            estimate: gl.getUniformLocation(program, 'estimate'),
            texel: gl.getUniformLocation(program, 'texel'),
            diffusion: gl.getUniformLocation(program, 'diffusion'),
            scratch: new target.__class__(fluid.width, fluid.height, target.textureFactory)
        };
    }

    fluid.diffuseViscosity = function(dt) {
        const value = simulation.wallpaperViscosity;
        if (!(value > 0) || !(dt > 0)) return;
        if (!resources) resources = createResources();
        const {program, quad, position, initial, estimate, texel, diffusion, scratch} = resources;
        if (scratch.width !== fluid.width || scratch.height !== fluid.height) scratch.resize(fluid.width, fluid.height);
        const target = fluid.velocityRenderTarget;
        const previousActiveTexture = gl.getParameter(gl.ACTIVE_TEXTURE);
        const amount = Math.pow(value / 100, 2) * 0.0002 * Math.min(dt, 0.05) * fluid.height * fluid.height;
        gl.viewport(0, 0, fluid.width, fluid.height);
        gl.useProgram(program);
        gl.bindBuffer(gl.ARRAY_BUFFER, quad);
        gl.enableVertexAttribArray(position);
        gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
        gl.uniform1i(initial, 0);
        gl.uniform1i(estimate, 1);
        gl.uniform2f(texel, 1 / fluid.width, 1 / fluid.height);
        gl.uniform1f(diffusion, amount);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, target.readFromTexture);
        let current = target.readFromTexture;
        for (let iteration = 0; iteration < 12; iteration++) {
            gl.activeTexture(gl.TEXTURE1);
            gl.bindTexture(gl.TEXTURE_2D, current);
            scratch.activate();
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
            scratch.swap();
            current = scratch.readFromTexture;
        }
        gl.uniform1f(diffusion, 0);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, current);
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, current);
        target.activate();
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        target.swap();
        gl.disableVertexAttribArray(position);
        gl.bindBuffer(gl.ARRAY_BUFFER, fluid.textureQuad);
        gl.useProgram(null);
        gl.activeTexture(previousActiveTexture);
    };

    const originalAdvect = fluid.advect;
    fluid.advect = function(target, dt) {
        originalAdvect.call(this, target, dt);
        if (target === this.velocityRenderTarget) this.diffuseViscosity(dt);
    };
}

function checkFluidViscosity(simulation) {
    const gl = simulation.gl;
    const template = simulation.fluid.velocityRenderTarget;
    const target = new template.__class__(32, 32, template.textureFactory);
    const probe = {gl, fluid: {width: 32, height: 32, textureQuad: simulation.fluid.textureQuad,
        velocityRenderTarget: target, advect() {}}};
    installFluidViscosity(probe);
    function sample(value, uniform) {
        const data = new Float32Array(32 * 32 * 4);
        for (let row = 0; row < 32; row++) {
            for (let column = 0; column < 32; column++) {
                const index = (row * 32 + column) * 4;
                data[index] = uniform ? 1 : (column % 2 ? -1 : 1);
                data[index + 3] = 1;
            }
        }
        gl.bindTexture(gl.TEXTURE_2D, target.readFromTexture);
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 32, 32, gl.RGBA, gl.FLOAT, data);
        probe.wallpaperViscosity = value;
        probe.fluid.diffuseViscosity(1 / 60);
        gl.bindFramebuffer(gl.FRAMEBUFFER, target.readFrameBufferObject);
        const pixels = new Float32Array(4);
        gl.readPixels(16, 16, 1, 1, gl.RGBA, gl.FLOAT, pixels);
        if (gl.getError() !== gl.NO_ERROR) throw new Error('Viscosity GPU probe failed');
        return pixels[0];
    }
    const unchanged = sample(0, false);
    const moderate = sample(50, false);
    const diffused = sample(100, false);
    const uniform = sample(100, true);
    const expected = 1 / (1 + 4 * 0.0002 * (1 / 60) * 32 * 32);
    if (Math.abs(unchanged - 1) > 0.001 || !(diffused < moderate && moderate < unchanged) ||
        Math.abs(diffused - expected) > 0.001 || Math.abs(uniform - 1) > 0.001) {
        throw new Error('Viscosity diffusion mismatch: ' + JSON.stringify({unchanged, moderate, diffused, uniform}));
    }
    return {unchanged, moderate, diffused, uniform};
}