/**
 * @file      rasterizeTools.h
 * @brief     Tools/utility functions for rasterization.
 * @authors   Yining Karl Li
 * @date      2012-2015
 * @copyright University of Pennsylvania
 */

#pragma once

#include <cmath>
#include <glm/glm.hpp>
#include <util/utilityCore.hpp>

struct AABB {
    glm::vec3 min;
    glm::vec3 max;
};

/**
 * Multiplies a glm::mat4 matrix and a vec4.
 */
__host__ __device__ static
glm::vec3 multiplyMV(glm::mat4 m, glm::vec4 v) {
    return glm::vec3(m * v);
}

// CHECKITOUT
/**
 * Finds the axis aligned bounding box for a given triangle within a given bound w and h.
 */
__host__ __device__ static
AABB getAABBForTriangle(const glm::vec3 tri[3], int w, int h) {
    AABB aabb;
    aabb.min = glm::vec3(
            min(min(tri[0].x, tri[1].x), tri[2].x),
            min(min(tri[0].y, tri[1].y), tri[2].y),
            min(min(tri[0].z, tri[1].z), tri[2].z));
	aabb.min.x = glm::clamp(aabb.min.x, 0.0f, (float)w);
	aabb.min.y = glm::clamp(aabb.min.y, 0.0f, (float)h);
	aabb.max = glm::vec3(
            max(max(tri[0].x, tri[1].x), tri[2].x),
            max(max(tri[0].y, tri[1].y), tri[2].y),
            max(max(tri[0].z, tri[1].z), tri[2].z));
	aabb.max.x = glm::clamp(aabb.max.x, 0.0f, (float)w);
	aabb.max.y = glm::clamp(aabb.max.y, 0.0f, (float)h);
	return aabb;
}

// CHECKITOUT
/**
 * Calculate the signed area of a given triangle.
 */
__host__ __device__ static
float calculateSignedArea(const glm::vec3 tri[3]) {
    return 0.5 * ((tri[2].x - tri[0].x) * (tri[1].y - tri[0].y) - (tri[1].x - tri[0].x) * (tri[2].y - tri[0].y));
}

// CHECKITOUT
/**
 * Helper function for calculating barycentric coordinates.
 */
__host__ __device__ static
float calculateBarycentricCoordinateValue(glm::vec2 a, glm::vec2 b, glm::vec2 c, const glm::vec3 tri[3]) {
    glm::vec3 baryTri[3];
    baryTri[0] = glm::vec3(a, 0);
    baryTri[1] = glm::vec3(b, 0);
    baryTri[2] = glm::vec3(c, 0);
    return calculateSignedArea(baryTri) / calculateSignedArea(tri);
}

// CHECKITOUT
/**
 * Calculate barycentric coordinates.
 */
__host__ __device__ static
glm::vec3 calculateBarycentricCoordinate(const glm::vec3 tri[3], glm::vec2 point) {
    float beta  = calculateBarycentricCoordinateValue(glm::vec2(tri[0].x, tri[0].y), point, glm::vec2(tri[2].x, tri[2].y), tri);
    float gamma = calculateBarycentricCoordinateValue(glm::vec2(tri[0].x, tri[0].y), glm::vec2(tri[1].x, tri[1].y), point, tri);
    float alpha = 1.0 - beta - gamma;
    return glm::vec3(alpha, beta, gamma);
}

// CHECKITOUT
/**
 * Check if a barycentric coordinate is within the boundaries of a triangle.
 */
__host__ __device__ static
bool isBarycentricCoordInBounds(const glm::vec3 barycentricCoord) {
    return barycentricCoord.x >= 0.0 && barycentricCoord.x <= 1.0 &&
           barycentricCoord.y >= 0.0 && barycentricCoord.y <= 1.0 &&
           barycentricCoord.z >= 0.0 && barycentricCoord.z <= 1.0;
}

// CHECKITOUT
/**
 * For a given barycentric coordinate, compute the corresponding z position
 * (i.e. depth) on the triangle.
 */
__host__ __device__ static
float getZAtCoordinate(const glm::vec3 barycentricCoord, const glm::vec3 tri[3]) {
    return -(barycentricCoord.x * tri[0].z
           + barycentricCoord.y * tri[1].z
           + barycentricCoord.z * tri[2].z);
}

__host__ __device__ static
glm::vec2 getTexccordAtCoordinate(const glm::vec3 barycentricCoord, const glm::vec2 texcoord[3]) {
	return (barycentricCoord.x * texcoord[0]
		+ barycentricCoord.y * texcoord[1]
		+ barycentricCoord.z * texcoord[2]);
}

/**
* For a given barycentric coordinate, compute the corresponding perspective correct z 
* position (i.e. depth) on the triangle.
*/
__host__ __device__ static
float getPerspectiveCorrectZAtCoordinate(const glm::vec3 screenSpaceBarycentric, const glm::vec3 tri[3]) 
{
	float inverseZ = screenSpaceBarycentric.x / tri[0].z + screenSpaceBarycentric.y / tri[1].z + screenSpaceBarycentric.z / tri[2].z;

	return 1.0f / inverseZ;
}

/**
* For a given barycentric coordinate, compute the corresponding perspective correct
* normals on the triangle.
*/
__host__ __device__ static
glm::vec3 getPerspectiveCorrectNormalAtCoordinate(const glm::vec3 barycentricCoord, const glm::vec3 tri[3], const glm::vec3 triNormals[3], float depth) {
	return glm::normalize(depth * glm::vec3(
		barycentricCoord.x * triNormals[0] / tri[0].z +
		barycentricCoord.y * triNormals[1] / tri[1].z +
		barycentricCoord.z * triNormals[2] / tri[2].z));
}

/**
* For a given barycentric coordinate, compute the corresponding perspective correct
* texture coordinate on the triangle.
*/
__host__ __device__ static
glm::vec2 getPerspectiveCorrectTexcoordAtCoordinate(const glm::vec3 barycentricCoord, const glm::vec3 tri[3], const glm::vec2 triTexCoord[3], float depth) {
	return depth * glm::vec2(
		barycentricCoord.x * triTexCoord[0] / tri[0].z +
		barycentricCoord.y * triTexCoord[1] / tri[1].z +
		barycentricCoord.z * triTexCoord[2] / tri[2].z);
}


// From https://devtalk.nvidia.com/default/topic/492068/atomicmin-with-float/
__device__ static
float fatomicMin(float *addr, float value)
{
	float old = *addr, assumed;
	if (old <= value) return old;
	do {
		assumed = old;
		old = atomicCAS((unsigned int*)addr, __float_as_int(assumed), __float_as_int(value));
	} while (old != assumed);
	
	return old;
}

// Adapted from Morgan McGuire on Implementing Weighted, Blended Order-Independent Transparency 
// at http://casual-effects.blogspot.com/2015/03/implemented-weighted-blended-order.html

__device__ static
void kBufferComputeAccumulativeAndRevealageBuffers(
	glm::vec3 premultipliedColor,
	float alpha,
	float depth
	) 
{

}