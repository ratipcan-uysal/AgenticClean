import Darwin
import Foundation
import Testing

@testable import CleanerCore

private enum SocketFixtureError: Error { case failure(Int32) }

private func listenerFixture(loopback: Bool) throws -> (Int32, UInt16) {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw SocketFixtureError.failure(errno) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = loopback ? inet_addr("127.0.0.1") : INADDR_ANY
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bound == 0, listen(fd, 1) == 0 else {
    let error = errno
    close(fd)
    throw SocketFixtureError.failure(error)
  }
  var size = socklen_t(MemoryLayout<sockaddr_in>.size)
  let read = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
  }
  guard read == 0 else {
    let error = errno
    close(fd)
    throw SocketFixtureError.failure(error)
  }
  return (fd, UInt16(bigEndian: address.sin_port))
}

private func ipv6ListenerFixture() throws -> (Int32, UInt16) {
  let fd = socket(AF_INET6, SOCK_STREAM, 0)
  guard fd >= 0 else { throw SocketFixtureError.failure(errno) }
  var address = sockaddr_in6()
  address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
  address.sin6_family = sa_family_t(AF_INET6)
  _ = inet_pton(AF_INET6, "::1", &address.sin6_addr)
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
    }
  }
  guard bound == 0, listen(fd, 1) == 0 else {
    let error = errno
    close(fd)
    throw SocketFixtureError.failure(error)
  }
  var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
  let read = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
  }
  guard read == 0 else {
    let error = errno
    close(fd)
    throw SocketFixtureError.failure(error)
  }
  return (fd, UInt16(bigEndian: address.sin6_port))
}

struct ListenerIntegrationTests {
  /// Creates only test-owned listening sockets, sends no requests and stops no user processes.
  @Test func observesOwnedLoopbackAndRejectsWildcardStaleAndClosedListeners() throws {
    let (localFD, localPort) = try listenerFixture(loopback: true)
    var localOpen = true
    defer { if localOpen { close(localFD) } }
    let (wildcardFD, wildcardPort) = try listenerFixture(loopback: false)
    defer { close(wildcardFD) }
    let (ipv6FD, ipv6Port) = try ipv6ListenerFixture()
    defer { close(ipv6FD) }
    let process = try #require(ProcessMonitor.read(getpid()))
    let listeners = try ProcessMonitor.listeners(for: process)
    let local = try #require(listeners.first { $0.port == localPort && $0.host == "127.0.0.1" })
    #expect(!listeners.contains { $0.port == wildcardPort })
    #expect(listeners.contains { $0.port == ipv6Port && $0.host == "::1" })
    #expect(try ProcessMonitor.validateListener(local))
    var replaced = process
    replaced.id = ProcessIdentity(pid: process.id.pid, seconds: process.id.seconds + 1)
    #expect(throws: ListenerError.self) { try ProcessMonitor.listeners(for: replaced) }
    close(localFD)
    localOpen = false
    #expect(try !ProcessMonitor.validateListener(local))
  }
}
