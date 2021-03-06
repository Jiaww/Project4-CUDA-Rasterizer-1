/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/random.h>
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <thrust/remove.h>
#include <thrust/execution_policy.h>

//#define RENDER_DEPTH_ONLY
//#define RENDER_NORMAL_ONLY
//#define BILINEAR_FILTERING
//#define BACKFACE_CULLING
//#define NOT_USE_TEXTURE
//#define USE_K_BUFFER
//#define SHARED_MEMORY_MATERIALS

	typedef unsigned short VertexIndex;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;
	typedef unsigned char TextureData;

	typedef unsigned char BufferByte;

	enum PrimitiveType{
		Point = 1,
		Line = 2,
		Triangle = 3
	};

	struct VertexOut {
		glm::vec4 pos;

		// TODO: add new attributes to your VertexOut
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
		 glm::vec4 color;
		 glm::vec2 texcoord0;
		 TextureData* dev_diffuseTex = NULL;
		 int texWidth, texHeight;
		 
		 int materialId;
	};

	struct Primitive {
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];
	};

	struct Fragment {
		glm::vec4 color;

		// TODO: add new attributes to your Fragment
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;

#ifdef RENDER_DEPTH_ONLY
		 float depth;
#endif
		 int materialId;

	};

	struct PrimitiveDevBufPointers {
		int primitiveMode;	//from tinygltfloader macro
		PrimitiveType primitiveType;
		int numPrimitives;
		int numIndices;
		int numVertices;

		// Vertex In, const after loaded
		VertexIndex* dev_indices;
		VertexAttributePosition* dev_position;
		VertexAttributeNormal* dev_normal;
		VertexAttributeTexcoord* dev_texcoord0;

		// Materials, add more attributes when needed
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		// TextureData* dev_specularTex;
		// TextureData* dev_normalTex;
		// ...

		int materialId;

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;

		// TODO: add more attributes when needed
	};

	struct Material {
		glm::vec4 diffuse;
		glm::vec4 ambient;
		glm::vec4 emission;
		glm::vec4 specular;
		float shininess;
		float transparency;
	};


static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Primitive* dev_culledPrimitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec4 *dev_framebuffer = NULL;
static int totalNumMaterials = 0;
static Material *dev_materials = NULL;

static float * dev_depth = NULL;	
static glm::vec4 * dev_depthAccum = NULL; // k-buffer accumulate
static float * dev_depthRevealage = NULL; // k-buffer revealage
/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ 
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec4 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec4 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
		color.w = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
		// Each thread writes one pixel location in the texture (textel)
        pbo[index].w = color.w;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

/** 
* Writes fragment colors to the framebuffer
*/
__global__
void render(
	int w, 
	int h, 
	Fragment *fragmentBuffer, 
	glm::vec4 *framebuffer, 
	float* depth,
	glm::vec4 *depthAccum, // k-buffer accumulate
	float* depthRevealage, // k-buffer revealage
	int numMaterials,
	Material* materials
	)
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

#if defined(SHARED_MEMORY_MATERIALS)
	// Materials copy has to be done here before any branching. 
	// Making an assumption that we could have maximum 256 materials
	__shared__ Material sh_materials[256];
	int mId = threadIdx.x + threadIdx.y * blockDim.x;

	// Doing a while loop here so every thread in a block can distribute work
	while (mId < numMaterials) {
		sh_materials[mId] = materials[mId];
		mId += blockDim.x * blockDim.y;
	}
	__syncthreads(); // Must sync here otherwise some threads won't get the right materials
#endif

    if (x < w && y < h) {

#ifdef RENDER_DEPTH_ONLY
		framebuffer[index] = glm::vec4(fragmentBuffer[index].depth, fragmentBuffer[index].depth, fragmentBuffer[index].depth, 1.0f);
#elif defined(RENDER_NORMAL_ONLY)
		framebuffer[index] = glm::vec4(glm::abs(fragmentBuffer[index].eyeNor), 1.f);
#else // Render with colors

		int materialId = fragmentBuffer[index].materialId;
		if (materialId != -1) {
			glm::vec3 lightDirection = glm::normalize(glm::vec3(-3.0f, 5.0f, 5.0f) - fragmentBuffer[index].eyePos);

		// Blinn-phong from Wikipedia: https://en.wikipedia.org/wiki/Blinn%E2%80%93Phong_shading_model
    	float lambertian = glm::clamp(
			glm::dot(fragmentBuffer[index].eyeNor, lightDirection), 
				0.0f, 1.0f);
		float specular = 0;

			if (lambertian > 0.0f) {
				glm::vec3 viewDirection = glm::normalize(-fragmentBuffer[index].eyePos);
				glm::vec3 halfDir = glm::normalize(lightDirection + viewDirection);
				float specAngle = glm::clamp(glm::dot(halfDir, fragmentBuffer[index].eyeNor), 0.0f, 1.0f);
				specular = glm::pow(specAngle, 
#if defined(SHARED_MEMORY_MATERIALS)
					(float)sh_materials[materialId].shininess
#else
					(float)materials[materialId].shininess
#endif				
						);
			}
			glm::vec4 diffuse =
#ifdef NOT_USE_TEXTURE		
#if defined(SHARED_MEMORY_MATERIALS)			
				sh_materials[materialId].diffuse;
#else
				materials[materialId].diffuse;
#endif // End SHARED_MEMORY_MATERIALS
			if (diffuse ==  glm::vec4(0, 0, 0, 1)) {
				// Diffuse is black, adjust it brighter
				diffuse = glm::vec4(1.0f, 1.0f, 1.0f, 1.0f);
			}
#else
			fragmentBuffer[index].color;
#endif // End NOT_USE_TEXTURE
			framebuffer[index] =
#if defined(SHARED_MEMORY_MATERIALS)
				sh_materials[materialId].ambient *
#else
				materials[materialId].ambient *
#endif // End SHARED_MEMORY_MATERIALS
				diffuse +
				lambertian * diffuse +
				specular *
#if defined(SHARED_MEMORY_MATERIALS)
				sh_materials[materialId].specular;
#else		
				materials[materialId].specular;
#endif // End SHARED_MEMORY_MATERIALS

		} else {
			framebuffer[index] = fragmentBuffer[index].color;
		}

#ifdef USE_K_BUFFER						
		framebuffer[index] = glm::vec4(glm::vec3(depthAccum[index]) / glm::max(depthAccum[index].a, 0.0001f), 1.0f - depthRevealage[index] ) / 50.0f; // Divide by 50.0f here to tone down the transparency

#endif // USE_K_BUFFER


#endif // End RENDER_DEPTH_ONLY, RENDER_NORMAL_ONLYr
    }
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;
	cudaFree(dev_fragmentBuffer);
	cudaMalloc(&dev_fragmentBuffer, width * height * sizeof(Fragment));
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec4));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec4));
    
	cudaFree(dev_depth);
	cudaMalloc(&dev_depth, width * height * sizeof(float));

	cudaFree(dev_depthAccum);
	cudaMalloc(&dev_depthAccum, width * height * sizeof(glm::vec4));

	cudaFree(dev_depthRevealage);
	cudaMalloc(&dev_depthRevealage, width * height * sizeof(float));

	checkCUDAError("rasterizeInit");

#ifdef BILINEAR_FILTERING
	printf("BILINEAR FILTERING ENABLED\n");
#endif

#ifdef USE_K_BUFFER
	printf("USING K-BUFFER\n");
#endif

#ifdef SHARED_MEMORY_MATERIALS
	printf("USING SHARED MEMORY FOR MATERIALS\n");
#endif
}

__global__
void initDepth(int w, int h, float * depth)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
	{
		int index = x + (y * w);
		depth[index] = INFINITY;
	}
}


/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__ 
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {
	
	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) {
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) {
			
			dev_dst[count * componentTypeByteSize * n 
				+ offset * componentTypeByteSize 
				+ j]

				= 

			dev_src[byteOffset 
				+ count * (byteStride == 0 ? componentTypeByteSize * n : byteStride) 
				+ offset * componentTypeByteSize 
				+ j];
		}
	}
	

}

__global__
void _nodeMatrixTransform(
	int numVertices,
	VertexAttributePosition* position,
	VertexAttributeNormal* normal,
	glm::mat4 MV, glm::mat3 MV_normal) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {
	
	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) {
		// matrix, copy it

		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	} else {
		// no matrix, use rotation, scale, translation

		if (n.translation.size() > 0) {
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) {
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) {
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode (
	std::map<std::string, glm::mat4> & n2m,
	const tinygltf::Scene & scene,
	const std::string & nodeString,
	const glm::mat4 & parentMatrix
	) 
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) {
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

	totalNumPrimitives = 0;
	std::map<std::string, BufferByte*> bufferViewDevPointers;
	
	int materialId = -1;
	std::vector<Material> materials;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) {
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) {
				continue; // Unsupported bufferView.
			}

			const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

			BufferByte* dev_bufferView;
			cudaMalloc(&dev_bufferView, bufferView.byteLength);
			cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

			checkCUDAError("Set BufferView Device Mem");

			bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

		}
	}



	// 2. for each mesh: 
	//		for each primitive: 
	//			build device buffer of indices, materail, and each attributes
	//			and store these pointers in a map
	{

		std::map<std::string, glm::mat4> nodeString2Matrix;
		auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

		{
			auto it = rootNodeNamesList.begin();
			auto itEnd = rootNodeNamesList.end();
			for (; it != itEnd; ++it) {
				traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
			}
		}


		// parse through node to access mesh

		auto itNode = nodeString2Matrix.begin();
		auto itEndNode = nodeString2Matrix.end();
		for (; itNode != itEndNode; ++itNode) {

			const tinygltf::Node & N = scene.nodes.at(itNode->first);
			const glm::mat4 & matrix = itNode->second;
			const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

			auto itMeshName = N.meshes.begin();
			auto itEndMeshName = N.meshes.end();

			for (; itMeshName != itEndMeshName; ++itMeshName) {

				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++) {
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = NULL;
					VertexAttributePosition* dev_position = NULL;
					VertexAttributeNormal* dev_normal = NULL;
					VertexAttributeTexcoord* dev_texcoord0 = NULL;

					// ----------Indices-------------

					const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
					const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
					BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

					// assume type is SCALAR for indices
					int n = 1;
					int numIndices = indexAccessor.count;
					int componentTypeByteSize = sizeof(VertexIndex);
					int byteLength = numIndices * n * componentTypeByteSize;

					dim3 numThreadsPerBlock(128);
					dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					cudaMalloc(&dev_indices, byteLength);
					_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
						numIndices,
						(BufferByte*)dev_indices,
						dev_bufferView,
						n,
						indexAccessor.byteStride,
						indexAccessor.byteOffset,
						componentTypeByteSize);


					checkCUDAError("Set Index Buffer");


					// ---------Primitive Info-------

					// Warning: LINE_STRIP is not supported in tinygltfloader
					int numPrimitives;
					PrimitiveType primitiveType;
					switch (primitive.mode) {
					case TINYGLTF_MODE_TRIANGLES:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices / 3;
						break;
					case TINYGLTF_MODE_TRIANGLE_STRIP:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_TRIANGLE_FAN:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_LINE:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices / 2;
						break;
					case TINYGLTF_MODE_LINE_LOOP:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices + 1;
						break;
					case TINYGLTF_MODE_POINTS:
						primitiveType = PrimitiveType::Point;
						numPrimitives = numIndices;
						break;
					default:
						// output error
						break;
					};


					// ----------Attributes-------------

					auto it(primitive.attributes.begin());
					auto itEnd(primitive.attributes.end());

					int numVertices = 0;
					// for each attribute
					for (; it != itEnd; it++) {
						const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
						const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

						int n = 1;
						if (accessor.type == TINYGLTF_TYPE_SCALAR) {
							n = 1;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC2) {
							n = 2;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC3) {
							n = 3;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC4) {
							n = 4;
						}

						BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
						BufferByte ** dev_attribute = NULL;

						numVertices = accessor.count;
						int componentTypeByteSize;

						// Note: since the type of our attribute array (dev_position) is static (float32)
						// We assume the glTF model attribute type are 5126(FLOAT) here

						if (it->first.compare("POSITION") == 0) {
							componentTypeByteSize = sizeof(VertexAttributePosition) / n;
							dev_attribute = (BufferByte**)&dev_position;
						}
						else if (it->first.compare("NORMAL") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
							dev_attribute = (BufferByte**)&dev_normal;
						}
						else if (it->first.compare("TEXCOORD_0") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
							dev_attribute = (BufferByte**)&dev_texcoord0;
						}

						std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

						dim3 numThreadsPerBlock(128);
						dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
						int byteLength = numVertices * n * componentTypeByteSize;
						cudaMalloc(dev_attribute, byteLength);

						_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
							n * numVertices,
							*dev_attribute,
							dev_bufferView,
							n,
							accessor.byteStride,
							accessor.byteOffset,
							componentTypeByteSize);

						std::string msg = "Set Attribute Buffer: " + it->first;
						checkCUDAError(msg.c_str());
					}

					// malloc for VertexOut
					VertexOut* dev_vertexOut;
					cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
					checkCUDAError("Malloc VertexOut Buffer");

					// ----------Materials-------------

					// You can only worry about this part once you started to 
					// implement textures for your rasterizer
					TextureData* dev_diffuseTex = NULL;
					int diffuseTexWidth = 0;
					int diffuseTexHeight = 0;
					Material material;
					if (!primitive.material.empty()) {
						const tinygltf::Material &mat = scene.materials.at(primitive.material);
						printf("material.name = %s\n", mat.name.c_str());

						if (mat.values.find("diffuse") != mat.values.end()) {
							std::string diffuseTexName = mat.values.at("diffuse").string_value;
							if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
								const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
								if (scene.images.find(tex.source) != scene.images.end()) {
									const tinygltf::Image &image = scene.images.at(tex.source);

									size_t s = image.image.size() * sizeof(TextureData);
									cudaMalloc(&dev_diffuseTex, s);
									cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);
									
									diffuseTexWidth = image.width;
									diffuseTexHeight = image.height;

									checkCUDAError("Set Texture Image data");
								}
							} else {
								auto diff = mat.values.at("diffuse").number_array;
								material.diffuse = glm::vec4(diff.at(0), diff.at(1), diff.at(2), diff.at(3));
							}
						}

						// TODO: write your code for other materails
						// You may have to take a look at tinygltfloader
						// You can also use the above code loading diffuse material as a start point 
						if (mat.values.find("ambient") != mat.values.end()) {
							auto amb = mat.values.at("ambient").number_array;
							material.ambient = glm::vec4(amb.at(0), amb.at(1), amb.at(2), amb.at(3));
						}
						if (mat.values.find("emission") != mat.values.end()) {
							auto em = mat.values.at("emission").number_array;
							material.emission = glm::vec4(em.at(0), em.at(1), em.at(2), em.at(3));

						}
						if (mat.values.find("specular") != mat.values.end()) {
							auto spec = mat.values.at("specular").number_array;
							material.specular = glm::vec4(spec.at(0), spec.at(1), spec.at(2), spec.at(3));

						}
						if (mat.values.find("shininess") != mat.values.end()) {
							material.shininess = mat.values.at("shininess").number_array.at(0);
						}

						if (mat.values.find("transparency") != mat.values.end()) {
							material.transparency = mat.values.at("transparency").number_array.at(0);
						} else {
							material.transparency = 1.0f;
						}

						materials.push_back(material);
						++materialId;
					}


					// ---------Node hierarchy transform--------
					cudaDeviceSynchronize();
					
					dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					_nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
						numVertices,
						dev_position,
						dev_normal,
						matrix,
						matrixNormal);

					checkCUDAError("Node hierarchy transformation");

					// at the end of the for loop of primitive
					// push dev pointers to map
					primitiveVector.push_back(PrimitiveDevBufPointers{
						primitive.mode,
						primitiveType,
						numPrimitives,
						numIndices,
						numVertices,

						dev_indices,
						dev_position,
						dev_normal,
						dev_texcoord0,

						dev_diffuseTex,
						diffuseTexWidth,
						diffuseTexHeight,
						
						materialId,
						dev_vertexOut	//VertexOut
					});

					totalNumPrimitives += numPrimitives;

				} // for each primitive

			} // for each mesh

		} // for each node

	}
	
	printf("Total number of primitives: %d\n", totalNumPrimitives);
	// 3. Malloc for dev_primitives
	{
		cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
		cudaMalloc(&dev_culledPrimitives, totalNumPrimitives * sizeof(Primitive));

	}
	
	// 4. Malloc for dev_materials
	{
		cudaMalloc(&dev_materials, materials.size() * sizeof(Material));
		totalNumMaterials = materials.size();
		printf("Number of materials %d\n", totalNumMaterials);
		cudaMemcpy(dev_materials, materials.data(), materials.size() * sizeof(Material), cudaMemcpyHostToDevice);
	}

	// Finally, cudaFree raw dev_bufferViews
	{

		std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
		std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());
			
			//bufferViewDevPointers

		for (; it != itEnd; it++) {
			cudaFree(it->second);
		}

		checkCUDAError("Free BufferView Device Mem");
	}


}



__global__ 
void _vertexTransformAndAssembly(
	int numVertices, 
	PrimitiveDevBufPointers primitive, 
	glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal, 
	int width, int height) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {

		// TODO: Apply vertex transformation here
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space
		glm::vec4 position = glm::vec4(primitive.dev_position[vid], 1.0f);
		glm::vec4 transformedPosition = MVP * position;
		transformedPosition /= transformedPosition.w;
		
		transformedPosition.x = 0.5f * static_cast<float>(width) * (transformedPosition.x + 1.0f);
		transformedPosition.y = 0.5f * static_cast<float>(height) * (1 - transformedPosition.y);

		// TODO: Apply vertex assembly here
		// Assemble all attribute arraies into the primitive array
		primitive.dev_verticesOut[vid].eyeNor = glm::normalize(MV_normal * primitive.dev_normal[vid]);

		glm::vec4 eyeSpacePosition = MV * glm::vec4(primitive.dev_position[vid], 1.0f);
		eyeSpacePosition /= eyeSpacePosition.w;
		primitive.dev_verticesOut[vid].eyePos = glm::vec3(eyeSpacePosition);
		primitive.dev_verticesOut[vid].pos = transformedPosition;

		if (primitive.dev_diffuseTex != NULL) {
			primitive.dev_verticesOut[vid].dev_diffuseTex = primitive.dev_diffuseTex;
			primitive.dev_verticesOut[vid].texcoord0 = primitive.dev_texcoord0[vid];
			primitive.dev_verticesOut[vid].texWidth = primitive.diffuseTexWidth;
			primitive.dev_verticesOut[vid].texHeight = primitive.diffuseTexHeight;
		} 
		primitive.dev_verticesOut[vid].materialId = primitive.materialId;
		primitive.dev_verticesOut[vid].color = glm::vec4(1.0, 1.0, 1.0, 1.0f);

	}
}



static int curPrimitiveBeginId = 0;

__global__ 
void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, Primitive* dev_primitives, PrimitiveDevBufPointers primitive) {

	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (iid < numIndices) {

		// TODO: uncomment the following code for a start
		// This is primitive assembly for triangles

		int pid;	// id for cur primitives vector
		if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES) {
			pid = iid / (int)primitive.primitiveType;
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
				= primitive.dev_verticesOut[primitive.dev_indices[iid]];
		}


		// TODO: other primitive types (point, line)
	}
	
}

// From Wikipedia: https://www.metromile.com/dashboard/password-reset?t=1fci1i9tg8vg6dlpa24raj7csd
__device__ __host__
glm::vec4 getBilinearFilteredPixelColor(TextureData* texels, glm::vec2 uv, int texWidth, int texHeight)
{
	float u = uv.s * texWidth - 0.5f;
	float v = uv.t * texHeight - 0.5f;
	int x = glm::floor(u);
	int y = glm::floor(v);
	float uRatio = u - x;
	float vRatio = v - y;
	float uOpposite = 1 - uRatio;
	float vOpposite = 1 - vRatio;
	int i0 = 3 * (x + y * texWidth);
	int i1 = 3 * ((x + 1) + y * texWidth);
	int i2 = 3 * (x + (y + 1) * texWidth);
	int i3 = 3 * ((x + 1) + (y + 1) * texWidth);

	float red = (texels[i0] * uOpposite +
		texels[i1] * uRatio) * vOpposite +
		(texels[i2] * uOpposite +
		texels[i3] * uRatio) * vRatio;
	float green = (texels[i0 + 1] * uOpposite +
		texels[i1 + 1] * uRatio) * vOpposite +
		(texels[i2 + 1] * uOpposite +
		texels[i3 + 1] * uRatio) * vRatio;
	float blue = (texels[i0 + 2] * uOpposite +
		texels[i1 + 2] * uRatio) * vOpposite +
		(texels[i2 + 2] * uOpposite +
		texels[i3 + 2] * uRatio) * vRatio;

	return glm::vec4(red, green, blue, 1.0f) / 255.0f;
}

__global__
void _rasterize(
	int numPrimitives, 
	Primitive* primitives,
	Fragment* fragmentBuffer,
	float * depths,
	glm::vec4 *depthAccum, // k-buffer accumulate
	float* depthRevealage, // k-buffer revealage
	int width,
	int height
	)
{
	// primitive id
	int pid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (pid < numPrimitives) {
		Primitive primitive = primitives[pid];

#ifdef BACKFACE_CULLING
		// Backface culling
		if (glm::dot(primitive.v[0].eyeNor, -primitive.v[0].eyePos) < 0.0f) {
			return;
		}
#endif

		// Compute bounding box for triangle
		glm::vec3 tri[3] = 
		{
			glm::vec3(primitive.v[0].pos),
			glm::vec3(primitive.v[1].pos),
			glm::vec3(primitive.v[2].pos)
		};
		AABB bbox = getAABBForTriangle(tri, width, height);

		// Loop through each fragment and check barycentric coordinates in bound
		for (int x = bbox.min.x; x <= bbox.max.x; ++x) {
			for (int y = bbox.min.y; y <= bbox.max.y; ++y) {
				
				// Compute barycentric coordinate for the given point
				// and compare that to see if the point is inside the 
				// triangle
				glm::vec2 point(x, y);
				glm::vec3 screenSpaceBarycentric = calculateBarycentricCoordinate(tri, point);

				if (isBarycentricCoordInBounds(screenSpaceBarycentric)) {

					// Interpolate depth
					float depth = getPerspectiveCorrectZAtCoordinate(screenSpaceBarycentric, tri);

					int index = x + (y * width);

					// Compute fragment values
#ifdef USE_K_BUFFER
					{
#else
					if (depth < depths[index]) {
						fatomicMin(&depths[index], depth);
#endif // End USE_K_BUFFER

						// Interpolate normal
						glm::vec3 eyeSpaceNormals[3] = {
							primitive.v[0].eyeNor,
							primitive.v[1].eyeNor,
							primitive.v[2].eyeNor
						};

						glm::vec3 perspectiveCorrectNormal = getPerspectiveCorrectNormalAtCoordinate(
							screenSpaceBarycentric, 
							tri,
							eyeSpaceNormals,
							depth);

						// Interpolate texture coords
						glm::vec2 uv;
						if (primitive.v[0].dev_diffuseTex != nullptr) {
							glm::vec2 texcoords[3] = {
								primitive.v[0].texcoord0,
								primitive.v[1].texcoord0,
								primitive.v[2].texcoord0
							};

							uv = getPerspectiveCorrectTexcoordAtCoordinate(
								screenSpaceBarycentric,
								tri,
								texcoords,
								depth
								);
						}
						// Write out fragment values
#ifdef  RENDER_DEPTH_ONLY
						fragmentBuffer[index].depth = fabs(depth);
#endif
						fragmentBuffer[index].eyeNor = perspectiveCorrectNormal;

						// If there is texture data, use it
						glm::vec4 color;
						if (primitive.v[0].dev_diffuseTex != nullptr) 
						{
							TextureData* texels = primitive.v[0].dev_diffuseTex;

#ifdef BILINEAR_FILTERING
							color = getBilinearFilteredPixelColor(texels, uv, primitive.v[0].texWidth, primitive.v[0].texHeight);
#else
							int texIndex =
								(int)(uv.s * primitive.v[0].texWidth) +
								(int)(uv.t * primitive.v[0].texWidth) * primitive.v[0].texHeight;

							color = glm::vec4(
								texels[3 * texIndex] / 255.0f,
								texels[3 * texIndex + 1] / 255.0f,
								texels[3 * texIndex + 2] / 255.0f, 1.0f);
									
#endif
						} 
						else 
						{
							color = primitive.v[0].color;
						}
						fragmentBuffer[index].materialId = primitive.v[0].materialId;

#ifdef USE_K_BUFFER			
						color.a = 0.1f;
						color.a *= (1.0f - glm::clamp((color.r + color.g + color.b) * (1.0f / 3.0f), 0.0f, 1.0f));

						float a = glm::min(1.0f, color.a) * 8.0 + 0.01;
						float b = depth * 0.95f + 1.0f;

						float w = glm::clamp(a * a * a * 1e8 * b * b * b, 1e-2, 3e2);
						atomicAdd(&depthAccum[index].r, color.r * w);
						atomicAdd(&depthAccum[index].g, color.g * w);
						atomicAdd(&depthAccum[index].b, color.b * w);
						atomicAdd(&depthAccum[index].w, color.w * w);
						depthRevealage[index] = color.a;
#endif
						// Final color
						fragmentBuffer[index].color = color;
					}
				}
			}
		}
	}
}


struct shouldBackfaceCull
{
	__host__ __device__
		bool operator()(const Primitive& p)
	{
		// Compute primitive face normal
		glm::vec4 edge1 = p.v[0].pos - p.v[1].pos;
		glm::vec4 edge2 = p.v[1].pos - p.v[2].pos;
		glm::vec3 faceNormal = glm::cross(glm::vec3(edge1), glm::vec3(edge2));
		return glm::dot(faceNormal, -p.v[0].eyePos) < 0.0f;
	};
};

/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) {
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);

	// Execute your rasterization pipeline here
	// (See README for rasterization pipeline outline.)

	// Vertex Process & primitive assembly
	{
		curPrimitiveBeginId = 0;
		dim3 numThreadsPerBlock(128);

		auto it = mesh2PrimitivesMap.begin();
		auto itEnd = mesh2PrimitivesMap.end();

		for (; it != itEnd; ++it) {
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p) {
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

				_vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> >(p->numVertices, *p, MVP, MV, MV_normal, width, height);
				checkCUDAError("Vertex Processing");
				cudaDeviceSynchronize();
				_primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
					(p->numIndices, 
					curPrimitiveBeginId, 
					dev_primitives, 
					*p);
				checkCUDAError("Primitive Assembly");

				curPrimitiveBeginId += p->numPrimitives;
			}
		}

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}

	int culledNumPrimitives = totalNumPrimitives;
	cudaMemcpy(dev_culledPrimitives, dev_primitives, totalNumPrimitives * sizeof(Primitive), cudaMemcpyDeviceToDevice);
#ifdef BACKFACE_CULLING
    {
		Primitive* dev_primitives_end = thrust::remove_if(thrust::device, dev_culledPrimitives, dev_culledPrimitives + totalNumPrimitives, shouldBackfaceCull());
		culledNumPrimitives = dev_primitives_end - dev_primitives;
		if (culledNumPrimitives <= 0) culledNumPrimitives = 1;
    }
#endif

	
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
	cudaMemset(dev_depthAccum, 0, width * height * sizeof(glm::vec4));
	cudaMemset(dev_depthRevealage, 1, width * height * sizeof(float));
	initDepth << <blockCount2d, blockSize2d >> >(width, height, dev_depth);
	
	// Rasterize
	{
		dim3 numThreadsPerBlock(128 < culledNumPrimitives ? 128 : culledNumPrimitives);
		dim3 numBlocksForPrimitives((culledNumPrimitives + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
		_rasterize<<<numBlocksForPrimitives, numThreadsPerBlock>>>(
			culledNumPrimitives,
			dev_culledPrimitives,
			dev_fragmentBuffer,
			dev_depth, 
			dev_depthAccum, 
			dev_depthRevealage,
			width, 
			height
			);
		checkCUDAError("rasterization");
	}


    // Copy depthbuffer colors into framebuffer
	render << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer, dev_framebuffer, dev_depth, dev_depthAccum, dev_depthRevealage, totalNumMaterials, dev_materials);
	checkCUDAError("fragment shader");
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("copy render result to pbo");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {

    // deconstruct primitives attribute/indices device buffer

	auto it(mesh2PrimitivesMap.begin());
	auto itEnd(mesh2PrimitivesMap.end());
	for (; it != itEnd; ++it) {
		for (auto p = it->second.begin(); p != it->second.end(); ++p) {
			cudaFree(p->dev_indices);
			cudaFree(p->dev_position);
			cudaFree(p->dev_normal);
			cudaFree(p->dev_texcoord0);
			cudaFree(p->dev_diffuseTex);

			cudaFree(p->dev_verticesOut);

			
			//TODO: release other attributes and materials
		}
	}

	////////////

	cudaFree(dev_materials);
	dev_materials = NULL;

    cudaFree(dev_primitives);
    dev_primitives = NULL;

	cudaFree(dev_culledPrimitives);
	dev_culledPrimitives = NULL;

	cudaFree(dev_fragmentBuffer);
	dev_fragmentBuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

	cudaFree(dev_depth);
	dev_depth = NULL;

	cudaFree(dev_depthRevealage);
	dev_depthRevealage = NULL;
	
	cudaFree(dev_depthAccum);
	dev_depthAccum = NULL;
	
	checkCUDAError("rasterize Free");
}
