// SPDX-License-Identifier: MIT
// Minimal Vulkan compute test: computes v = v * 2 + 1 over 64 integers on the
// GPU and verifies the result on the CPU. No window system involved.
//   make && ./vktest            (or: ./vktest path/to/shader.comp.spv)
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static const char *cs_path = "shader.comp.spv";

#define CHK(x) do { VkResult r_ = (x); fprintf(stderr, "  -> %s = %d\n", #x, (int)r_); if (r_) exit(1); } while (0)

int main(int argc, char **argv) {
	if (argc > 1) cs_path = argv[1];
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	fprintf(stderr, "STEP instance\n");
	CHK(vkCreateInstance(&ici, NULL, &inst));

	uint32_t ndev = 0;
	CHK(vkEnumeratePhysicalDevices(inst, &ndev, NULL));
	if (!ndev) { printf("FAIL: no devices\n"); return 1; }
	VkPhysicalDevice *pdev = calloc(ndev, sizeof(*pdev));
	CHK(vkEnumeratePhysicalDevices(inst, &ndev, pdev));
	VkPhysicalDevice pd = pdev[0];
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(pd, &props);
	printf("device: %s\n", props.deviceName);

	uint32_t qf = 0, nq = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
	VkQueueFamilyProperties *qfp = calloc(nq ? nq : 1, sizeof(*qfp));
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qfp);
	for (uint32_t i = 0; i < nq; i++)
		if (qfp[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qf = i; break; }
	fprintf(stderr, "STEP device (qf=%u of %u)\n", qf, nq);

	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = qf, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	CHK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, qf, 0, &queue);

	FILE *f = fopen(cs_path, "rb");
	if (!f) { printf("no shader.comp.spv (run glslangValidator)\n"); return 1; }
	fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
	uint32_t *code = malloc(sz);
	if (fread(code, 1, sz, f) != (size_t)sz) return 1;
	fclose(f);
	VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = sz, .pCode = code };
	VkShaderModule mod;
	fprintf(stderr, "STEP shader\n");
	CHK(vkCreateShaderModule(dev, &smci, NULL, &mod));

	VkDescriptorSetLayoutBinding lb = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
	VkDescriptorSetLayoutCreateInfo dlci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1, .pBindings = &lb };
	VkDescriptorSetLayout dsl;
	CHK(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dsl));

	VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &dsl };
	VkPipelineLayout pl;
	CHK(vkCreatePipelineLayout(dev, &plci, NULL, &pl));

	VkComputePipelineCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = mod, .pName = "main" },
		.layout = pl };
	VkPipeline pipe;
	fprintf(stderr, "STEP pipeline\n");
	CHK(vkCreateComputePipelines(dev, 0, 1, &pci, NULL, &pipe));

	VkDescriptorPoolSize ps = { .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 };
	VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
		.maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool pool;
	CHK(vkCreateDescriptorPool(dev, &dpci, NULL, &pool));

	VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
	VkDescriptorSet ds;
	CHK(vkAllocateDescriptorSets(dev, &dsai, &ds));

	const uint32_t N = 64;
	uint32_t data[N];
	for (uint32_t i = 0; i < N; i++) data[i] = i;

	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
		.size = sizeof(data), .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
		.sharingMode = VK_SHARING_MODE_EXCLUSIVE };
	VkBuffer buf;
	fprintf(stderr, "STEP buffer\n");
	CHK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buf, &mr);

	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t mt = 0;
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((mr.memoryTypeBits & (1u << i)) &&
		    (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) { mt = i; break; }

	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = mr.size, .memoryTypeIndex = mt };
	VkDeviceMemory mem;
	fprintf(stderr, "STEP allocmem (type %u)\n", mt);
	CHK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CHK(vkBindBufferMemory(dev, buf, mem, 0));

	void *p;
	fprintf(stderr, "STEP map\n");
	CHK(vkMapMemory(dev, mem, 0, sizeof(data), 0, &p));
	memcpy(p, data, sizeof(data));

	VkDescriptorBufferInfo dbi = { .buffer = buf, .offset = 0, .range = sizeof(data) };
	VkWriteDescriptorSet w = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
		.dstSet = ds, .dstBinding = 0, .descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);

	VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = qf };
	VkCommandPool cpool;
	CHK(vkCreateCommandPool(dev, &cpi, NULL, &cpool));
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = cpool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cb;
	CHK(vkAllocateCommandBuffers(dev, &cai, &cb));

	VkCommandBufferBeginInfo beg = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CHK(vkBeginCommandBuffer(cb, &beg));
	vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
	vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
	vkCmdDispatch(cb, 1, 1, 1);
	CHK(vkEndCommandBuffer(cb));

	VkFence fence;
	VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	CHK(vkCreateFence(dev, &fci, NULL, &fence));
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
		.commandBufferCount = 1, .pCommandBuffers = &cb };
	fprintf(stderr, "STEP submit\n");
	CHK(vkQueueSubmit(queue, 1, &si, fence));
	fprintf(stderr, "STEP wait\n");
	CHK(vkWaitForFences(dev, 1, &fence, VK_TRUE, (uint64_t)-1));

	memcpy(data, p, sizeof(data));
	int ok = 1;
	for (uint32_t i = 0; i < N; i++)
		if (data[i] != i * 2 + 1) { ok = 0; printf("mismatch at %u: %u\n", i, data[i]); break; }
	printf(ok ? "GPU COMPUTE OK: 64 values processed on the GPU correctly\n"
	          : "GPU COMPUTE FAILED\n");
	return ok ? 0 : 1;
}
