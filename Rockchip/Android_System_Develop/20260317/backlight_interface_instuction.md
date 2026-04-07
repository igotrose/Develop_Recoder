# 背光控制接口说明

## 1. 功能说明
本接口用于控制设备屏幕背光亮度。
说明：
- `0` 表示关闭背光
- `1 ~ 255` 表示打开背光并设置亮度
- 本接口控制的是背光，不等同于系统休眠或标准灭屏

## 2. 接口形式
应用通过 `Context.getSystemService()` 获取背光控制对象
服务名：
```java
Context.RK_BACKLIGHT_SERVICE
```
获取示例：
```java
RkBacklightManager manager = (RkBacklightManager) context.getSystemService(Context.RK_BACKLIGHT_SERVICE);
```
## 3. 接口定义
```java
public class RkBacklightManager { 
    int setBacklight(int level);
    int getBacklight();
}
```
## 4. 接口说明
### 4.1 setBacklight
```java
int setBacklight(int level)
```
功能：
- 设置背光亮度

参数：
- `level`：背光亮度，取值范围：`0 ~ 255`

参数含义：
- `0` ：关闭背光
- `1 ~ 255` ：打开背光并设置亮度

返回值：
- `0`：成功
- `-1`：服务不可用
- `-2`：参数错误
- `-3`：权限不足
- `-4`：其他错误

说明：
- 关闭设置背光之后不会触发系统休眠，不发送系统广播，应用可以继续进行
## 4.2 getBacklight
```java
int getBacklight()
```
功能：
- 获取背光亮度

返回值：
- `0 ~ 255`：当前背光亮度
# 5. 调用方式
```java
RkBacklightManager manager =
        (RkBacklightManager) context.getSystemService(Context.RK_BACKLIGHT_SERVICE);

int ret = manager.setBacklight(0);
ret = manager.setBacklight(128);

int level = manager.getBacklight(); 
```
## 5. 设备验证 `console`
- 系统服务注册
    ```bash
    service list | grep rk_backlight 
    ```
- 设置背光服务
    ```bash 
    service call rk_backlight 1 i32 128
    # 或者
    echo 128 > /sys/class/backlight/backlight/brightness
    ```
    - `service call` 调用 `Binder` 服务
    - `rk_backlight` 服务名
    - `1` 函数编号，第一个函数
    - `i32` 参数类型，int32
    - `128` 函数参数
- 获取背光服务
    ```bash 
    service call rk_backlight 2
    # 或者
    cat /sys/class/backlight/backlight/brightness
    ```

