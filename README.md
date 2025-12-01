# AMD NPU Reverse Engineering
For now we target the mainline kernel driver (amdxdna). There is also a kernel driver by AMD that is very similar to the mainline one with slight differences.
The main thing we are trying to replace is the XRT runtime, essentially the userspace driver.
### IOCTLs
After opening /dev/accel/accel0 there are a few IOCTLs that we can call.
- **CREATE_HWCTX**
	- Creates a hardware context. For now we give it the same args as XRT.
- **DESTROY_HWCTX**
	- Self explanatory.
- **CONFIG_HWCTX**
	- Used to upload the CU configuration code, probably how each tile connects to other tiles. 
- **CREATE_BO**
	- Create a buffer object, which means mapping a portion of memory as SHARED so that the NPU can access it. 
	- There are multiple uses such as CMD buffers, dev heap, etc.
- **GET_BO_INFO**
	- Gets the map_offset of the BO that is used to actually mmap the memory.
- **SYNC_BO**
- **EXEC_CMD**
	- Uploads code and executes it on the NPU. Must call **CONFIG_HWCTX** before. 
	- Need to research opcodes.
- **GET_INFO**
	- Get various information about the NPU's state.
- **SET_STATE**
	- Configure general parameters of the NPU.
- **GET_ARRAY**
- **GEM_CLOSE**
	- Not part of the amdxdna driver, but this is what we use to destroy BOs.
### Basic usage
1. Open /dev/accel/accel0
2. Create DEV_HEAP:
	Create BO of size 64MiB and of type DEV_HEAP. Allocate memory with mmap (needs to be aligned to 64MiB). Mmap with the fd and map_offset from GET_BO_INFO.
	Note: You need to run `ulimit -S -l 100000` before because linux has a low default limit for LOCKED memory and we need 64MiB.
3. Create HWCTX
4. Config CUs:
    Create BO with type DEV.
	???
5. Create and execute CMD BO
### XRT Observations
- Uses .xclbin to store stuff? and ELF for the ctrlcode (sent to EXEC_CMD) and ctrldata (???)
### Misc
- Mainline kernel driver might be incomplete, hence the out-of-tree driver
- Maybe we can bypass the kernel driver, like AM runtime in tinygrad
- The firmware looks simple and might be reverse-engineerable, which could simplify the usage on the NPU a lot, but this is kind of out-of-scope
- Pretty much no useful documentation anywhere, only a bit on the general architecture and registers: 
	- https://docs.amd.com/r/en-US/am009-versal-ai-engine/
	- https://docs.amd.com/r/en-US/am020-versal-aie-ml/
