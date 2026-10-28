// Optional isolated native integration probe. Build with the Go standard library.
// Only loopback destinations are probed; no system service is touched.
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type obj = map[string]any

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func readJSON(path string) obj {
	b, e := os.ReadFile(path)
	must(e)
	var v obj
	must(json.Unmarshal(b, &v))
	return v
}
func writeJSON(path string, v any) {
	b, e := json.Marshal(v)
	must(e)
	must(os.WriteFile(path, b, 0600))
}
func start(bin string, args ...string) func() {
	c := exec.Command(bin, args...)
	var log bytes.Buffer
	c.Stdout = &log
	c.Stderr = &log
	must(c.Start())
	return func() {
		_ = c.Process.Kill()
		_ = c.Wait()
		if os.Getenv("VPSBOX_NATIVE_DEBUG") == "1" {
			fmt.Print(log.String())
		}
	}
}
func waitTCP(addr string) {
	for i := 0; i < 100; i++ {
		c, e := net.DialTimeout("tcp", addr, 50*time.Millisecond)
		if e == nil {
			c.Close()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	panic("listener timeout: " + addr)
}
func address(host string, port int) []byte {
	ip := net.ParseIP(host)
	var result []byte
	if ip == nil {
		result = append([]byte{3, byte(len(host))}, []byte(host)...)
	} else if v4 := ip.To4(); v4 != nil {
		result = append([]byte{1}, v4...)
	} else {
		result = append([]byte{4}, ip.To16()...)
	}
	return append(result, byte(port>>8), byte(port))
}
func socksHost(addr string, command byte, host string, port int) net.Conn {
	c, e := net.DialTimeout("tcp", addr, time.Second)
	must(e)
	defer func() {
		if r := recover(); r != nil {
			c.Close()
			panic(r)
		}
	}()
	must(c.SetDeadline(time.Now().Add(5 * time.Second)))
	_, e = c.Write([]byte{5, 1, 0})
	must(e)
	b := make([]byte, 2)
	_, e = io.ReadFull(c, b)
	must(e)
	if !bytes.Equal(b, []byte{5, 0}) {
		panic("SOCKS authentication")
	}
	request := append([]byte{5, command, 0}, address(host, port)...)
	_, e = c.Write(request)
	must(e)
	b = make([]byte, 4)
	_, e = io.ReadFull(c, b)
	must(e)
	if b[1] != 0 {
		panic(fmt.Sprintf("SOCKS reply: %v", b))
	}
	n := 16
	if b[3] == 1 {
		n = 4
	}
	tail := make([]byte, n+2)
	_, e = io.ReadFull(c, tail)
	must(e)
	if command == 3 {
		udpRelay = net.JoinHostPort(net.IP(tail[:n]).String(), fmt.Sprint(binary.BigEndian.Uint16(tail[n:])))
	}
	return c
}
func socks(addr string, command byte, ip net.IP, port int) net.Conn {
	return socksHost(addr, command, ip.String(), port)
}

func forwardTCP(host string, port int) (err error) {
	return forwardHTTP(host, port, "native.example")
}
func forwardHTTP(host string, port int, httpHost string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("%v", r)
		}
	}()
	c := socksHost("127.0.0.1:29103", 1, host, port)
	defer c.Close()
	_, err = c.Write([]byte("GET / HTTP/1.0\r\nHost: " + httpHost + "\r\n\r\n"))
	must(err)
	data, err := io.ReadAll(c)
	must(err)
	if !bytes.Contains(data, []byte("vpsbox-native-ok")) {
		return fmt.Errorf("no TCP echo")
	}
	return nil
}
func forwardUDP(host string, port int) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("%v", r)
		}
	}()
	c := socks("127.0.0.1:29103", 3, net.IPv4zero, 0)
	defer c.Close()
	u, e := net.Dial("udp", udpRelay)
	must(e)
	defer u.Close()
	must(u.SetDeadline(time.Now().Add(time.Second)))
	packet := append([]byte{0, 0, 0}, address(host, port)...)
	packet = append(packet, []byte("udp-native-ok")...)
	_, e = u.Write(packet)
	must(e)
	b := make([]byte, 2048)
	n, e := u.Read(b)
	must(e)
	if !bytes.HasSuffix(b[:n], []byte("udp-native-ok")) {
		return fmt.Errorf("no UDP echo")
	}
	return nil
}

func forwardTLS(port int, name string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("%v", r)
		}
	}()
	c := socksHost("127.0.0.1:29103", 1, "127.0.0.1", port)
	defer c.Close()
	// Local fixture certificate; the test varies SNI to exercise server-side sniffing.
	t := tls.Client(c, &tls.Config{ServerName: name, InsecureSkipVerify: true})
	defer t.Close()
	return t.Handshake()
}

func policyChecks(protocol, family string, tcpPort, udpPort, tlsPort int) {
	for _, c := range []struct {
		host  string
		allow bool
	}{
		{"127.0.0.1", true}, {"127.0.0.2", false}, {"::1", false},
		{"allowed.native.test", true}, {"blocked4.native.test", false}, {"blocked6.native.test", false},
		{"mixed.native.test", false}, {"missing.native.test", false},
		{"blocked-domain.native.test", false}, {"child.blocked-domain.native.test", false},
		{"cn123.native.test", false},
	} {
		err := forwardTCP(c.host, tcpPort)
		if (err == nil) != c.allow {
			panic(fmt.Sprintf("%s %s TCP %s allow=%v err=%v", protocol, family, c.host, c.allow, err))
		}
		if protocol == "shadowsocks" || protocol == "vless" {
			err = forwardUDP(c.host, udpPort)
			if (err == nil) != c.allow {
				panic(fmt.Sprintf("UDP %s allow=%v err=%v", c.host, c.allow, err))
			}
		}
		fmt.Printf("PASS %s %s policy %s allow=%v\n", protocol, family, c.host, c.allow)
	}
	for _, c := range []struct {
		name  string
		allow bool
	}{
		{"allowed.native.test", true}, {"blocked-domain.native.test", false},
		{"child.blocked-domain.native.test", false}, {"cn123.native.test", false},
	} {
		err := forwardHTTP("127.0.0.1", tcpPort, c.name)
		if (err == nil) != c.allow {
			panic(fmt.Sprintf("HTTP sniff %s allow=%v err=%v", c.name, c.allow, err))
		}
		err = forwardTLS(tlsPort, c.name)
		if (err == nil) != c.allow {
			panic(fmt.Sprintf("TLS sniff %s allow=%v err=%v", c.name, c.allow, err))
		}
		fmt.Printf("PASS %s %s HTTP/TLS sniff %s allow=%v\n", protocol, family, c.name, c.allow)
	}
}

var udpRelay string

func main() { must(run()) }
func run() error {
	bin, dir, family := os.Args[1], os.Args[2], os.Args[3]
	policy := len(os.Args) > 4 && os.Args[4] == "policy"
	ip := "127.0.0.1"
	if family == "ipv6" {
		ip = "::1"
	}
	// IPv6 wildcard provides one echo port for IPv4 and IPv6 loopback targets.
	target, e := net.Listen("tcp", "[::]:0")
	must(e)
	defer target.Close()
	go http.Serve(target, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "vpsbox-native-ok") }))
	udp, e := net.ListenPacket("udp", "[::]:0")
	must(e)
	defer udp.Close()
	go func() {
		b := make([]byte, 2048)
		for {
			n, a, e := udp.ReadFrom(b)
			if e != nil {
				return
			}
			_, _ = udp.WriteTo(b[:n], a)
		}
	}()
	key, e := rsa.GenerateKey(rand.Reader, 2048)
	must(e)
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "native.example"}, DNSNames: []string{"native.example"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, e := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	must(e)
	pair, e := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
	must(e)
	reality, e := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS13, NextProtos: []string{"h2", "http/1.1"}})
	must(e)
	defer reality.Close()
	go http.Serve(reality, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "reality-target") }))
	vlessPath := filepath.Join(dir, "20-vless-reality.json")
	vless := readJSON(vlessPath)
	vi := vless["inbounds"].([]any)[0].(map[string]any)
	vr := vi["tls"].(map[string]any)["reality"].(map[string]any)
	vr["handshake"] = obj{"server": "127.0.0.1", "server_port": reality.Addr().(*net.TCPAddr).Port}
	writeJSON(vlessPath, vless)
	if policy {
		path := filepath.Join(dir, "30-egress-policy.json")
		config := readJSON(path)
		config["dns"] = obj{"servers": []any{obj{"type": "hosts", "tag": "vpsbox-egress-dns", "predefined": obj{
			"allowed.native.test": []string{"127.0.0.1"}, "blocked4.native.test": []string{"127.0.0.2"},
			"blocked6.native.test": []string{"::1"}, "mixed.native.test": []string{"127.0.0.1", "::1"},
			"blocked-domain.native.test": []string{"127.0.0.1"}, "child.blocked-domain.native.test": []string{"127.0.0.1"},
			"cn123.native.test": []string{"127.0.0.1"},
		}}}}
		writeJSON(path, config)
	}
	raw, e := base64.RawURLEncoding.DecodeString(vr["private_key"].(string))
	must(e)
	priv, e := ecdh.X25519().NewPrivateKey(raw)
	must(e)
	stop := start(bin, "run", "-C", dir)
	defer stop()
	for _, protocol := range []string{"shadowsocks", "vless"} {
		port := 29101
		if protocol == "vless" {
			port = 29102
		}
		waitTCP(net.JoinHostPort(ip, fmt.Sprint(port)))
		out := obj{"type": protocol, "server": ip, "server_port": port}
		if protocol == "shadowsocks" {
			si := readJSON(filepath.Join(dir, "10-ss.json"))["inbounds"].([]any)[0].(map[string]any)
			out["method"] = si["method"]
			out["password"] = si["password"]
		} else {
			out["uuid"] = vi["users"].([]any)[0].(map[string]any)["uuid"]
			out["flow"] = "xtls-rprx-vision"
			out["tls"] = obj{"enabled": true, "server_name": "native.example", "utls": obj{"enabled": true, "fingerprint": "chrome"}, "reality": obj{"enabled": true, "public_key": base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes()), "short_id": vr["short_id"].([]any)[0]}}
		}
		client := filepath.Join(filepath.Dir(dir), "client.json")
		writeJSON(client, obj{"log": obj{"level": "error"}, "inbounds": []any{obj{"type": "socks", "listen": "127.0.0.1", "listen_port": 29103}}, "outbounds": []any{out}})
		func() {
			stopClient := start(bin, "run", "-c", client)
			defer stopClient()
			waitTCP("127.0.0.1:29103")
			if policy {
				policyChecks(protocol, family, target.Addr().(*net.TCPAddr).Port, udp.LocalAddr().(*net.UDPAddr).Port, reality.Addr().(*net.TCPAddr).Port)
				return
			}
			c := socks("127.0.0.1:29103", 1, net.ParseIP(ip), target.Addr().(*net.TCPAddr).Port)
			defer c.Close()
			_, e = c.Write([]byte("GET / HTTP/1.0\r\nHost: native.example\r\n\r\n"))
			must(e)
			data, e := io.ReadAll(c)
			must(e)
			if !bytes.Contains(data, []byte("vpsbox-native-ok")) {
				panic("TCP forwarding failed")
			}
			fmt.Printf("PASS %s %s TCP\n", protocol, family)
			if protocol == "shadowsocks" || protocol == "vless" {
				control := socks("127.0.0.1:29103", 3, net.IPv4zero, 0)
				defer control.Close()
				u, e := net.Dial("udp", udpRelay)
				must(e)
				defer u.Close()
				must(u.SetDeadline(time.Now().Add(5 * time.Second)))
				p := udp.LocalAddr().(*net.UDPAddr).Port
				dst := net.ParseIP(ip).To16()
				atyp := byte(4)
				if family == "ipv4" {
					dst = net.ParseIP(ip).To4()
					atyp = 1
				}
				packet := append([]byte{0, 0, 0, atyp}, dst...)
				packet = append(packet, byte(p>>8), byte(p))
				packet = append(packet, []byte("udp-native-ok")...)
				_, e = u.Write(packet)
				must(e)
				b := make([]byte, 2048)
				n, e := u.Read(b)
				must(e)
				if !bytes.HasSuffix(b[:n], []byte("udp-native-ok")) {
					panic("UDP forwarding failed")
				}
				fmt.Printf("PASS %s %s UDP\n", protocol, family)
			}
		}()
	}
	return nil
}
