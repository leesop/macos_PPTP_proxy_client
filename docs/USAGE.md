# 사용법 도움말

[첫 페이지로 돌아가기](../README.md) · [최신 버전 다운로드](https://github.com/leesop/macos_PPTP_proxy_client/releases/latest) · [English](#english)

## 시작 전 확인

- **OS X El Capitan 10.11 이하**에서는 macOS 내장 PPTP VPN을 먼저 사용하세요. **macOS Sierra 10.12부터** 내장 PPTP 연결이 제거됐습니다. 이 앱은 **macOS 14 이상**에서 실행하며 특정 앱의 프락시·TCP 연결만 처리합니다. [Apple의 PPTP 지원 종료 안내](https://support.apple.com/en-us/100860)
- Apple Silicon Mac과 macOS 14 이상이 필요합니다.
- PPTP 서버 주소, VPN 아이디와 암호를 준비합니다. 서버가 PPTP 및 PPP/MPPE 연결을 받아야 합니다.
- Mac에서 서버까지 PPTP 제어 연결과 GRE 통신이 가능해야 합니다.
- 앱은 시스템 전체 VPN이 아닙니다. HTTP·SOCKS5 프락시를 사용하는 앱 또는 지정한 TCP 포트만 터널을 이용합니다.

## 설치와 프로필 저장

1. [릴리스](https://github.com/leesop/macos_PPTP_proxy_client/releases/latest)에서 `PPTPProxy-notarized.zip`을 다운로드하고 압축을 풉니다.
2. `PPTPProxy.app`을 실행합니다. 앱은 Developer ID로 서명되고 Apple 공증을 받았습니다.
3. **프로필·연결**에서 이름, **PPTP 서버**, **VPN 아이디**, **VPN 암호**를 입력하고 **저장**을 누릅니다. 이름을 비우면 서버 주소를 이름으로 사용합니다.
4. 기존 프로필은 **프로필** 목록에서 선택합니다. 저장된 암호는 키체인에 보관되며 암호를 바꿀 때만 새 암호를 입력하면 됩니다.

프로필의 **삭제**를 누르면 앱에 저장된 프로필과 해당 키체인 암호가 함께 삭제됩니다.

## PPTP 연결

**연결**을 누르면 macOS가 관리자 권한을 요청할 수 있습니다. 백엔드가 GRE 소켓을 열기 위한 절차입니다. 앱 상단 상태가 **PPP/MPPE 연결됨**으로 바뀔 때까지 기다리세요. 연결되면 화면이 **프락시 설정**으로 이동합니다.

연결에 실패하면 **프로필·연결 → 로그 보기**를 눌러 원인을 확인합니다. PPP/MPPE 협상이 끝나기 전에는 프락시 요청이 전달되지 않습니다.

## 프락시 사용

기본 주소는 다음과 같습니다. 포트를 바꾸려면 앱의 **프락시 설정**에서 입력하고 **적용**을 누르세요.

| 방식 | 기본 주소 | 용도 |
| --- | --- | --- |
| HTTP | `127.0.0.1:18080` | HTTP 및 `CONNECT`를 지원하는 HTTPS 클라이언트 |
| SOCKS5 | `127.0.0.1:11080` | SOCKS5를 지원하는 프로그램 |

프락시 주소를 프로그램별로 지정할 수 있다면 해당 프로그램에만 설정하는 편이 사용 범위를 이해하기 쉽습니다. Safari에서 사용하려면 macOS **시스템 설정 → 네트워크 → 사용 중인 네트워크 → 세부사항 → 프락시**에서 **웹 프락시(HTTP)**와 **보안 웹 프락시(HTTPS)**의 서버를 `127.0.0.1`, 포트를 `18080`으로 설정합니다. macOS 시스템 프락시를 따르는 다른 앱에도 영향을 줄 수 있으므로 사용을 마치면 해당 설정을 해제하세요. [Apple의 프락시 설정 안내](https://support.apple.com/guide/mac-help/change-proxy-settings-on-mac-mchlp2591/mac)

## TCP 포트포워딩

**프락시 설정 → 수동 포트포워딩**에 규칙을 한 줄씩 입력합니다.

```text
15432:10.0.0.5:5432
18081:legacy.example.com:80
```

첫 번째 규칙은 이 Mac의 `127.0.0.1:15432`로 들어온 TCP 연결을 PPTP 내부의 `10.0.0.5:5432`로 보냅니다. 두 번째 규칙은 로컬 `18081` 포트를 원격 웹 서버의 `80` 포트로 보냅니다. 규칙을 입력한 뒤 **적용**을 누르세요. 연결 중 설정을 바꾸면 새로 들어오는 연결부터 적용됩니다.

한 규칙은 `로컬포트:대상호스트:대상포트` 형식입니다. 포트는 `1`부터 `65535`까지이며 로컬 포트는 서로 달라야 합니다. HTTP·SOCKS5 포트와도 겹칠 수 없습니다. 이 기능은 TCP만 지원하고 로컬 포트는 `127.0.0.1`에만 열립니다.

## 상태 확인과 연결 해제

창 상단에서 연결 상태, 보낸·받은 데이터 양, 연결 시간을 확인할 수 있습니다. **연결 해제**를 누르면 앱이 백엔드에 종료를 요청합니다. 창을 닫거나 앱을 종료할 때 연결 중이면 확인 창이 나타납니다.

연결이 끊겼는데 포트가 계속 사용 중이라면 **프로필·연결 → 남은 연결 정리**를 사용하세요. 이 기능은 이 앱의 백엔드 실행 파일인지 확인한 뒤 남은 프로세스에 종료를 요청하며 관리자 권한을 다시 요구할 수 있습니다.

## 문제 해결

| 증상 | 확인할 점 |
| --- | --- |
| **연결** 직후 실패 | 서버 주소·VPN 계정·암호와 관리자 권한 승인을 확인하고 **로그 보기**의 오류를 읽습니다. |
| `PPTP 데이터 채널이 열리지 않았습니다` | Mac과 서버 사이 네트워크에서 GRE가 통과하는지 확인합니다. |
| PPP 협상 또는 인증 실패 | 서버의 PPTP/PPP/MPPE 설정과 VPN 계정을 확인합니다. |
| **적용** 시 로컬 포트 오류 | 다른 앱이 해당 포트를 사용 중인지 확인하고 비어 있는 포트로 바꿉니다. 충돌 시 기존 설정이 유지됩니다. |
| 연결됐지만 대상 프로그램이 접속하지 못함 | 프로그램의 프락시 설정 또는 `127.0.0.1:로컬포트` 접속 주소를 확인합니다. 시스템 전체 트래픽이 자동으로 PPTP로 바뀌지는 않습니다. |
| 종료 후 포트가 계속 열려 있음 | **남은 연결 정리**를 사용하고 다시 연결합니다. |

PPTP는 오래된 프로토콜입니다. 가능한 환경이라면 서버를 현대적인 VPN 프로토콜로 전환하는 편이 좋습니다. 이 앱은 PPTP만 남아 있는 장비와 서비스를 위한 호환 수단입니다.

---

## English

# Usage and troubleshooting

[Project home](../README.md#english) · [Latest release](https://github.com/leesop/macos_PPTP_proxy_client/releases/latest) · [한국어](#사용법-도움말)

### Before you start

**OS X El Capitan 10.11 and earlier** include a built-in PPTP VPN client. If PPTP is necessary on those systems, use the built-in VPN connection first. Apple removed it starting with **macOS Sierra 10.12**. This app runs on **Apple Silicon macOS 14 or later** and carries only proxy and explicitly forwarded TCP traffic. [Apple's PPTP removal notice](https://support.apple.com/en-us/100860)

Have the PPTP server address, VPN user name, and password ready. The network must allow the PPTP control connection and GRE traffic to reach the server. The server must accept PPTP and PPP/MPPE connections.

### Install and save a profile

1. Download `PPTPProxy-notarized.zip` from the [latest release](https://github.com/leesop/macos_PPTP_proxy_client/releases/latest), unzip it, and launch `PPTPProxy.app`.
2. On **Profiles & Connection**, enter a profile name, **PPTP Server**, **VPN User Name**, and **VPN Password**, then click **Save**. If you leave the profile name blank, the server address is used.
3. To reuse a profile, select it from **Profile**. Passwords are stored in the macOS Keychain; enter a new password only when changing it. **Delete** removes both the profile and its stored password.

### Connect

Click **Connect** and approve the macOS administrator prompt if shown. The backend needs permission to open a GRE socket. Wait for **PPP/MPPE connected**; the app then opens **Proxy Settings**. Use **Show Log** on **Profiles & Connection** if the connection fails. Proxy requests are blocked until PPP/MPPE negotiation completes.

### Configure a proxy

| Type | Default address | Use |
| --- | --- | --- |
| HTTP | `127.0.0.1:18080` | HTTP clients and HTTPS clients that use `CONNECT` |
| SOCKS5 | `127.0.0.1:11080` | Programs that support SOCKS5 |

To change a port, enter it under **Proxy Settings** and click **Apply**. Configuring a proxy in a single program limits the effect to that program. For Safari, use macOS **System Settings → Network → current network → Details → Proxies** and set both **Web Proxy (HTTP)** and **Secure Web Proxy (HTTPS)** to `127.0.0.1` on port `18080`. This system setting may also affect other apps that honor it; turn it off when finished. [Apple's proxy setup guide](https://support.apple.com/guide/mac-help/change-proxy-settings-on-mac-mchlp2591/mac)

### Forward TCP ports

Enter one rule per line under **Proxy Settings → Manual Port Forwarding**, then click **Apply**:

```text
15432:10.0.0.5:5432
18081:legacy.example.com:80
```

The first rule forwards TCP connections to this Mac's `127.0.0.1:15432` through PPTP to `10.0.0.5:5432`. The second forwards local port `18081` to the remote server's port `80`. Rules use `local-port:destination-host:destination-port`. Ports must be between `1` and `65535`, and local ports must not overlap each other or the proxy ports. Listeners bind only to `127.0.0.1`. Changes made while connected apply to new connections.

### Status and disconnecting

The top of the window shows connection status, bytes sent and received, and elapsed time. Click **Disconnect** to stop the backend. Quitting while connected shows a confirmation dialog. If a port remains occupied after a failed disconnect, use **Profiles & Connection → Clean Up Remaining Connection**; this checks that the process belongs to this app and may request administrator permission.

### Troubleshooting

| Symptom | What to check |
| --- | --- |
| Connect fails immediately | Check the server, account, password, administrator approval, and **Show Log**. |
| PPTP data channel does not open | Check whether GRE passes between the Mac and the server. |
| PPP negotiation or authentication fails | Check the server's PPTP/PPP/MPPE settings and the VPN account. |
| **Apply** reports a local port error | Another app may be using the port. Choose a free port; the previous settings remain active after a conflict. |
| Connected, but a program cannot reach its target | Check that program's proxy settings or the forwarded `127.0.0.1:local-port` address. System-wide traffic is not redirected automatically. |
| Port remains open after disconnect | Use **Clean Up Remaining Connection**, then connect again. |

PPTP is a legacy protocol. Migrate the server to a modern VPN protocol when possible. This app is a compatibility option for devices and services that still require PPTP.
