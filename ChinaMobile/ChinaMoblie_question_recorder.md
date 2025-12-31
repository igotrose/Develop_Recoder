# 中移开发问题记录
## 2025-08-05
### Linux开发环境搭建
- 参考文档
```《芯昇科技CM8620芯片-软件快速START.pdf》```
1. `xmake`安装
```bash
sudo add-apt-repository ppa:xmake-io/xmake
sudo apt update
sudo apt install xmake
```
2. `doc2unix`安装，将windows格式的文档转换为unix格式的文档
```bash
sudo apt install doc2unix
doc2unix <filename>
```
3. `riscv64-unknown-elf`交叉编译工具链安装，配置环境变量
```bash
tar -xvf ict_build.tar
vim setup_env.sh && chmod +x setup_enc.sh

#!/bin/bash
export TOOLCHAIN_PATH="/opt/ict-build/ZCnuclei/linux/bin"
export PATH="$TOOLCHAIN_PATH:$PATH"
export CROSS_COMPILE="riscv64-unknown-elf-"
alias python=python3
echo "CM8620OC toolchain loaded:"
riscv64-unknown-elf-gcc --version 2>/dev/null || echo "compiler not found"
echo "🔧 usage: source setup_env.sh"
```
4. 编译，编译成功后，全版本存放在当前目录下的 `bin/version/`目录下，合一版本固件位于`bin/one.bin`
```bash
# 编译中间文件清除操作
./build.sh PRJ=op-mdl clean-all
# 全编译
./build.sh PRJ=op-mdl 
# 编译帮助
./build.sh help
```
### 编译问题
- `cannot execute 'cc1': execvp: No such file or directory`,找不到编译器路径，编译器的路径未加到`PATH`
```bash
export PATH="/opt/ict-build/ZCnuclei/linux/bin:$PATH"
export CROSS_COMPILE="riscv64-unknown-elf-"
```
- Python2/3兼容问题，在`setup_env.sh`中添加`alias python=python3`
- 镜像大小超限问题，可以通过修改配置里的位于`src\board\openphone\cfg`分区表`partition.xlsx`然后修改分区，生成并替换`xpartition.ini`配置
- 如果遇到格式问题没有通过`doc2unix`解决，可以手动操作一下
```bash
# 检查脚本文件是否有格式问题
find . -name "*.sh" -exec file {} \; | grep CRLF
# 将格式问题的脚本文件转换为unix格式
find . -name "*.sh" -exec dos2unix {} \;
```
- 在执行`tools/partition.py`中出现读取获取输入文件错误，是因为输入变量的问题，报错如下
```bash
Traceback (most recent call last):
  File "tools/partition.py", line 18, in <module>
    ff = open(input_file, encoding='utf8')
TypeError: 'encoding' is an invalid keyword argument for this function
error: exec(python tools/partition.py src/board/openphone/cfg/xpartition.ini /home/ubuntu/ubuntu_2204_workplace/ChinaMobile/CM8620OC-V1.0.1-beta-SDK/bin/oc/ap/partition.cfg) failed(1)
```
修改如下
```python
# tools/partition.py
import io
ff = io.open(input_file, 'r', encoding='utf8')
```
- 对于使用了python调用的脚本，显式使用python3进行编译调用
## 2025-08-27
### ML307R模组AT指令联网
- 参考文档
  `芯昇科技CM8620芯片-AT命令手册.pdf`
- 插入有效sim卡，有流量再手机上能够上网，执行一下AT指令
  ```bash
  AT+
  ```