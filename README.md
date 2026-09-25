# PPTP 프락시 for macOS

최신 macOS에서 오래된 PPTP 서버에 접속해야 할 때 쓰는 Apple Silicon용 프락시 앱입니다. **macOS 14 이상**에서 실행하며, HTTP·SOCKS5 프락시와 TCP 포트포워딩을 통해 필요한 프로그램의 연결만 PPTP로 보냅니다. 시스템 전체 VPN 인터페이스나 기본 경로는 만들지 않습니다.

[최신 버전 다운로드](https://github.com/leesop/macos_PPTP_proxy_client/releases/latest) · [사용법과 문제 해결](docs/USAGE.md) · [소스 및 라이선스](#소스-및-라이선스)

배포본은 [GitHub Releases](https://github.com/leesop/macos_PPTP_proxy_client/releases)에서 `PPTPProxy-notarized.zip`을 받으세요. 앱은 Developer ID로 서명하고 Apple 공증 티켓을 첨부했습니다. ZIP에는 `PPTPProxy.app`, 안내문, 대응 소스 아카이브가 들어 있습니다. 압축을 푼 뒤 `PPTPProxy.app`을 실행하면 됩니다.

## 만든 이유

과거 macOS에서는 PPTP VPN 접속을 설정할 수 있었지만, 이후 해당 기능이 사라졌습니다. 여전히 PPTP 서버를 쓰는 오래된 장비나 환경에 접근하려면 다른 방법이 필요합니다. Apple도 현재 VPN API에서 PPTP를 지원하지 않는 레거시 프로토콜로 분류합니다. [Apple 개발자 문서](https://developer.apple.com/documentation/networkextension/personal-vpn)

기존 오픈소스 클라이언트를 조합하거나 경량 Linux VM을 띄우는 방법도 검토했습니다. 하지만 설치·권한·네트워크 설정과 운용 부담이 이 용도에 비해 크다고 판단했습니다. 그래서 접속 대상을 프락시를 사용할 수 있는 프로그램과 지정한 TCP 포트로 한정하고, 프로필 저장·연결·설정 변경·연결 해제를 macOS 앱에서 다룰 수 있도록 만들었습니다. 필요한 연결을 더 간편하고 안정적으로 사용하려는 설계입니다.

## 주요 기능과 범위

- PPTP 제어 채널과 GRE: 번들된 오픈소스 `pptp` 1.10.0
- PPP, MS-CHAPv2, MPPE 128비트, IPCP, DNS, TCP/IP: 번들된 오픈소스 `lwIP` 2.2.1
- macOS는 VPN 인터페이스와 시스템 경로를 생성하지 않습니다. 프락시 또는 로컬 포트포워딩으로 들어온 TCP 연결만 사용자 공간 PPP 링크로 보냅니다.
- DNS 이름은 PPP에서 받은 DNS 서버를 `lwIP`가 터널 안에서 조회합니다.
- PPP/MPPE 협상이 끝나기 전의 요청은 거부합니다.
- 프로필을 앱 설정에, VPN 암호를 macOS 키체인에 저장하고 연결 상태·전송량·로그를 표시합니다.

## 빠른 시작

1. [릴리스](https://github.com/leesop/macos_PPTP_proxy_client/releases/latest)에서 `PPTPProxy-notarized.zip`을 내려받아 압축을 풀고 `PPTPProxy.app`을 실행합니다. 배포 앱은 Developer ID 서명과 Apple 공증을 마쳤습니다.
2. **프로필·연결**에서 PPTP 서버 주소, VPN 아이디와 암호를 입력하고 **저장**을 누릅니다.
3. **연결**을 누르고 macOS 관리자 권한 요청을 승인합니다. GRE 소켓을 열기 위해 필요합니다.
4. 상태가 **PPP/MPPE 연결됨**으로 바뀌면 필요한 앱에 `127.0.0.1:18080` HTTP 프락시 또는 `127.0.0.1:11080` SOCKS5 프락시를 설정합니다. 특정 TCP 서비스는 **프락시 설정**에서 포트포워딩 규칙을 추가합니다.

Safari 및 macOS 네트워크 프락시 설정, 포트포워딩 예시, 연결 오류 확인 방법은 [사용법 도움말](docs/USAGE.md)에 단계별로 적었습니다.

## 확인된 범위와 제약

- ARM64에서 앱과 백엔드가 빌드됐고 코드 서명 검증을 통과했습니다. 로컬 HTTP·SOCKS5·포트포워딩 리스너, PPP 미연결 시 요청 차단, 연결 중 설정 변경과 포트 충돌 시 기존 설정 유지, 로컬 연결 해제를 시험했습니다.
- 실제 서버와 PPP/MPPE 연결 상태를 확인했습니다. 사용자는 프락시를 통한 연결 동작을 확인했고, 버전 0.5.2에서 실제 연결 후 **연결 해제**를 눌러 앱이 연결 안 됨 상태로 돌아가고 HTTP·SOCKS5 포트가 닫히는 것을 확인했습니다.
- 프락시 포트와 포워딩 포트는 IPv4 루프백 `127.0.0.1`에만 열립니다. 일반 시스템 전체 VPN, UDP 포워딩, IPv6, HTTPS 프락시 서버 자체의 TLS 종단은 제공하지 않습니다. `HTTPS` 사이트는 HTTP 프락시의 `CONNECT`로 전달됩니다.
- 관리자 권한은 연결 시작 때마다 macOS가 요구할 수 있습니다. 백엔드는 raw GRE socket을 사용하므로 권한 없이 연결할 수 없습니다.
- PPTP와 MS-CHAPv2/MPPE는 오래된 보안 기술입니다. 서버를 더 안전한 프로토콜로 바꿀 수 없는 환경에서 사용하세요.

## 소스 및 라이선스

이 저장소에 앱/백엔드 소스와 빌드에 사용한 오픈소스 소스를 공개했습니다. 같은 릴리스의 `PPTPProxy-source.tar.gz`도 해당 빌드의 소스 묶음이며 배포 ZIP 안에도 들어 있습니다. Apple Silicon macOS 14 이상에서 Xcode Command Line Tools와 CMake를 설치한 뒤 `./build.command`로 로컬 빌드를 재현할 수 있습니다. 이 명령은 기본적으로 로컬 임시 서명을 사용합니다.

- `pptp` 1.10.0: [PPTP Client](https://pptpclient.sourceforge.net/), GPL-2.0-or-later. 원본 소스는 `pptp-1.10.0.tar.gz`, 라이선스 전문은 아카이브의 `COPYING`과 앱 `Contents/Resources/PPTP-COPYING`에 있습니다.
- `lwIP` 2.2.1: [lwIP](https://github.com/lwip-tcpip/lwip/tree/STABLE-2_2_1_RELEASE), BSD-3-Clause. 소스는 `lwip/`, 저작권·라이선스 고지는 `lwip/COPYING`과 앱 `Contents/Resources/lwIP-COPYING`에 있습니다.

GPL 대상인 `pptp` 실행 파일과 같은 릴리스에 대응 소스를 제공하며, 바이너리 배포와 동일하게 누구나 다운로드할 수 있습니다. 이 저장소의 자체 작성 코드에 대한 별도의 오픈소스 라이선스는 지정하지 않았습니다.
