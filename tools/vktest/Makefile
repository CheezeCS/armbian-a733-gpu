# Needs: libvulkan-dev glslang-tools
all: vktest shader.comp.spv

vktest: vktest.c
	$(CC) -O2 -Wall -o $@ $< -lvulkan

shader.comp.spv: shader.comp
	glslangValidator -V $< -o $@

clean:
	rm -f vktest shader.comp.spv

.PHONY: all clean
