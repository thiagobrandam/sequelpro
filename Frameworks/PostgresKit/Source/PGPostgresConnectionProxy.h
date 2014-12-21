//
//  PGPostgresConnectionProxy.h
//  PostgresKit
//
//  Created by thiago on 12/6/14.
//
//

/**
 * Connection proxy state constants.
 */
typedef enum {
    PGPostgresProxyIdle				= 0,
    PGPostgresProxyConnecting			= 1,
    PGPostgresProxyWaitingForAuth		= 2,
    PGPostgresProxyConnected			= 3,
    PGPostgresProxyForwardingFailed	= 4
} PGPostgresConnectionProxyState;


@protocol PGPostgresConnectionProxy <NSObject>

/**
 * All the methods for this protocol are required.
 */

/**
 * Connect the proxy.
 */
- (void)connect;

/**
 * Disconnect the proxy.
 */
- (void)disconnect;

/**
 * Get the current state of the proxy.
 */
- (PGPostgresConnectionProxyState)state;

/**
 * Get the local port being provided by the proxy.
 */
- (NSUInteger)localPort;

/**
 * Sets the method the proxy should call whenever the state of the connection changes.
 */
- (BOOL)setConnectionStateChangeSelector:(SEL)theStateChangeSelector delegate:(id)theDelegate;

@end
