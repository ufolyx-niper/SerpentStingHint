# Serpent Sting Hint

供 WoW Forever 1.60.1 的猎人使用。解压 ZIP，将整个 `SerpentStingHint` 文件夹放到 `World of Warcraft/_forever_/Interface/AddOns/`，重新启动游戏。插件独立运行。

| 当前敌对目标的状态 | 图标 |
| --- | --- |
| 有你施放的毒蛇钉刺 | 显示剩余秒数 |
| 没有你的毒蛇钉刺，且估计还能活超过 10 秒 | 金框高亮 |
| 没有你的毒蛇钉刺，开怪时估不出击杀时间，且当前血量至少 5,000 点 | 金框高亮 |
| 没有你的毒蛇钉刺，且以上两个高亮条件均未满足 | 灰色 |

图标默认在屏幕中心偏右下方。`/sshint 140 -100` 可以设置相对屏幕中心的水平和垂直偏移，`/sshint reset` 恢复默认。

倒计时由客户端按目标身上的实际减益绘制。预计击杀时间来自当前目标掉血速度，单刷和组队都适用。每次切换目标会重新采样，至少观察到 3 次受伤事件、经过 2 秒并有足够的掉血量才会使用击杀时间。5 秒没有新受伤事件就丢弃旧估计。集火变化、转阶段和治疗会影响估算。

5,000 点是当前剩余血量的门槛。选中敌对目标后，插件在观察到目标进入战斗或首次受伤起的 6 秒内，可以用这条规则填补估算空窗。插件需要读到当前目标的最大血量才能使用点数门槛。如果最大血量无法取得，就等击杀时间有足够样本再判断。

这是本地测试候选。已通过 Lua 模拟验证，暴雪原生减益容器的实际渲染和团本中的估算仍需进游戏验证。

## 源码参考与许可

- 减益容器与裁剪方式参考 [EverAuras](https://github.com/Hackblarvest/EverAuras/tree/014c64f6116362f7a9e1da9e450367f42616a937) 的 `ForeverEngineAura.lua`。本插件按 GPL-2.0-only 提供，见 `LICENSE`。
- 掉血速度投影及健康曲线参考 [Last Breath Forever](https://github.com/KesaObscura/LastBreathForever/tree/c86f41c93865867d3519acb6ee845f9d0ab7cd88)。其 MIT 许可及版权声明见 `LICENSE-LastBreathForever`。
- 参考了 [Musca Auras](https://github.com/dldvlpr-addons-wow/Musca-Auras/tree/b7109e439f77033ca4cefb0b8cc17b94c3b04095) 使用原生减益容器的实现。
