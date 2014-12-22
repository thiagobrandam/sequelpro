//
//  PGPostgresConnection+Copying.m
//  PostgresKit
//
//  Created by thiago on 12/21/14.
//
//

#import "PGPostgresConnection+Copying.h"

@implementation PGPostgresConnection (Copying)

/**
 * Provide a copy of the SPMySQLConnection instance.
 * The copy should inherit the full setup, but will not inherit
 * the connection state - it will not be connected, and any connection
 * details such as the selected database/encoding will not be inherited.
 * Note that any proxy will not be referenced in the new connection, and
 * should also be set if desired.
 */
- (id)copyWithZone:(NSZone *)zone
{
    PGPostgresConnection *copy = [[[self class] allocWithZone:zone] init];
    
    // Synthesized details
    [copy setDelegate:_delegate];
    [copy setHost:_host];
    [copy setUser:_user];
    [copy setPassword:_password];
    [copy setPort:_port];
    [copy setUseSocket:_useSocket];
    [copy setSocketPath:_socketPath];
//    [copy setUseSSL:useSSL];
//    [copy setSslKeyFilePath:sslKeyFilePath];
//    [copy setSslCertificatePath:sslCertificatePath];
//    [copy setSslCACertificatePath:sslCACertificatePath];
    [copy setTimeout:_timeout];
    [copy setUseKeepAlive:_useKeepAlive];
//    [copy setRetryQueriesOnConnectionFailure:retryQueriesOnConnectionFailure];
//    [copy setDelegateQueryLogging:delegateQueryLogging];
    
    // Active connection state details, like selected database and encoding, are *not* copied.
    
    return copy;
}


@end
