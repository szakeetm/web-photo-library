// Runs shaders/edit.wgsl with WebGPU — the same file the server runs on Metal, so what the editor
// shows is what gets saved. The luminance passes depend only on the source image and run once per photo.
import shaderCode from '../../../../shaders/edit.wgsl?raw';
import { lumaSize, outputSize, shaderParams, type Recipe } from './recipe';

export type Source = ImageBitmap | { data: Uint8Array; width: number; height: number };

export class EditRenderer {
	private module: GPUShaderModule;
	private sampler: GPUSampler;
	private pipelines = new Map<string, GPURenderPipeline>();
	private src: GPUTexture | null = null;
	private lumaA: GPUTexture | null = null;
	private lumaB: GPUTexture | null = null;
	width = 0;
	height = 0;

	/** `gpu` and `adapter` are kept referenced: with Dawn in Node, collecting them frees the device. */
	private constructor(
		readonly device: GPUDevice,
		private readonly keepAlive: unknown[]
	) {
		this.module = device.createShaderModule({ code: shaderCode });
		this.sampler = device.createSampler({ minFilter: 'linear', magFilter: 'linear', addressModeU: 'clamp-to-edge', addressModeV: 'clamp-to-edge' });
	}

	/** Null when this browser has no WebGPU (the editor then explains why it is unavailable). */
	static async create(gpu: GPU | undefined = globalThis.navigator?.gpu): Promise<EditRenderer | null> {
		if (!gpu) return null;
		const adapter = await gpu.requestAdapter();
		if (!adapter) return null;
		const device = await adapter.requestDevice();
		device.addEventListener('uncapturederror', (e) => console.error('WebGPU:', (e as GPUUncapturedErrorEvent).error.message));
		return new EditRenderer(device, [gpu, adapter]);
	}

	private pipeline(entry: string, format: GPUTextureFormat) {
		const key = `${entry}/${format}`;
		let p = this.pipelines.get(key);
		if (!p) {
			p = this.device.createRenderPipeline({
				layout: 'auto',
				vertex: { module: this.module, entryPoint: 'vs_main' },
				fragment: { module: this.module, entryPoint: entry, targets: [{ format }] },
				primitive: { topology: 'triangle-list' }
			});
			this.pipelines.set(key, p);
		}
		return p;
	}

	/** Uploads the (Display-P3) base image and computes its blurred luminance. */
	setSource(source: Source) {
		this.src?.destroy();
		this.lumaA?.destroy();
		this.lumaB?.destroy();
		const { width, height } = source;
		this.width = width;
		this.height = height;
		this.src = this.device.createTexture({
			size: [width, height],
			format: 'rgba8unorm',
			usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT
		});
		if ('data' in source) {
			this.device.queue.writeTexture({ texture: this.src }, source.data as Uint8Array<ArrayBuffer>, { bytesPerRow: width * 4 }, [width, height]);
		} else {
			this.device.queue.copyExternalImageToTexture({ source }, { texture: this.src, colorSpace: 'display-p3' }, [width, height]);
		}
		const l = lumaSize(width, height);
		const lumaTex = () =>
			this.device.createTexture({ size: [l.w, l.h], format: 'rgba16float', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.RENDER_ATTACHMENT });
		this.lumaA = lumaTex();
		this.lumaB = lumaTex();
		const enc = this.device.createCommandEncoder();
		const params = (blur: [number, number]) => shaderParams({ schema: 1 }, 1, 1, width, height, blur);
		this.pass(enc, 'fs_luma', this.lumaA, params([0, 0]));
		this.pass(enc, 'fs_blur', this.lumaB, params([1, 0]), this.lumaA);
		this.pass(enc, 'fs_blur', this.lumaA, params([0, 1]), this.lumaB);
		this.submit(enc);
	}

	/** Uniform buffers of the passes being encoded; destroyed once their work is submitted. */
	private pending: GPUBuffer[] = [];

	private submit(enc: GPUCommandEncoder) {
		this.device.queue.submit([enc.finish()]);
		for (const b of this.pending) b.destroy();
		this.pending = [];
	}

	private pass(enc: GPUCommandEncoder, entry: string, target: GPUTexture, params: Float32Array, luma?: GPUTexture) {
		const pipeline = this.pipeline(entry, target.format);
		// Each pass gets its own uniform buffer: passes in one submission must not share mutable state.
		const ubo = this.device.createBuffer({ size: 256, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
		new Float32Array(ubo.getMappedRange()).set(params);
		ubo.unmap();
		const entries: GPUBindGroupEntry[] = [{ binding: 0, resource: { buffer: ubo } }];
		if (entry !== 'fs_blur') entries.push({ binding: 1, resource: this.src!.createView() }, { binding: 2, resource: this.sampler });
		if (entry !== 'fs_luma') entries.push({ binding: 3, resource: (luma ?? this.lumaA!).createView() });
		const bind = this.device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries });
		const rp = enc.beginRenderPass({ colorAttachments: [{ view: target.createView(), loadOp: 'clear', storeOp: 'store', clearValue: [0, 0, 0, 1] }] });
		rp.setPipeline(pipeline);
		rp.setBindGroup(0, bind);
		rp.draw(3);
		rp.end();
		this.pending.push(ubo);
	}

	outputSize(recipe: Recipe) {
		return outputSize(recipe, this.width, this.height);
	}

	/** Renders into `target` (its size must equal outputSize(recipe)). */
	render(recipe: Recipe, target: GPUTexture) {
		if (!this.src) throw new Error('no source');
		const enc = this.device.createCommandEncoder();
		this.pass(enc, 'fs_develop', target, shaderParams(recipe, target.width, target.height, this.width, this.height));
		this.submit(enc);
	}

	/** Renders and reads the pixels back (RGBA8, Display P3). */
	async renderPixels(recipe: Recipe): Promise<{ data: Uint8Array; width: number; height: number }> {
		const { w, h } = this.outputSize(recipe);
		const tex = this.device.createTexture({ size: [w, h], format: 'rgba8unorm', usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC });
		this.render(recipe, tex);
		const data = await this.readTexture(tex, w, h);
		tex.destroy();
		return { data, width: w, height: h };
	}

	async readTexture(tex: GPUTexture, w: number, h: number) {
		const bytesPerRow = Math.ceil((w * 4) / 256) * 256;
		const buf = this.device.createBuffer({ size: bytesPerRow * h, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
		const enc = this.device.createCommandEncoder();
		enc.copyTextureToBuffer({ texture: tex }, { buffer: buf, bytesPerRow }, [w, h]);
		this.device.queue.submit([enc.finish()]);
		await buf.mapAsync(GPUMapMode.READ);
		const src = new Uint8Array(buf.getMappedRange());
		const out = new Uint8Array(w * h * 4);
		for (let y = 0; y < h; y++) out.set(src.subarray(y * bytesPerRow, y * bytesPerRow + w * 4), y * w * 4);
		buf.unmap();
		buf.destroy();
		return out;
	}

	destroy() {
		this.src?.destroy();
		this.lumaA?.destroy();
		this.lumaB?.destroy();
		this.device.destroy();
	}
}
