//
//  $Id: PGPostgresConnection.m 3848 2012-09-12 12:19:31Z stuart02 $
//
//  PGPostgresConnection.m
//  PostgresKit
//
//  Copyright (c) 2008-2009 David Thorpe, djt@mutablelogic.com
//
//  Forked by the Sequel Pro Team on July 22, 2012.
// 
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not 
//  use this file except in compliance with the License. You may obtain a copy of 
//  the License at
// 
//  http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software 
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT 
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the 
//  License for the specific language governing permissions and limitations under
//  the License.

#import "PGPostgresConnection.h"
#import "PGPostgresConnectionParameters.h"
#import "PGPostgresConnectionTypeHandling.h"
#import "PGPostgresKitPrivateAPI.h"
#import "PGPostgresTypeHandlerProtocol.h"
#import "PGPostgresTypeNumberHandler.h"
#import "PGPostgresTypeStringHandler.h"
#import "PGPostgresException.h"
#import "PGPostgresStatement.h"
#import "PGPostgresResult.h"

#import <pthread.h>
#import <poll.h>

@interface PGPostgresConnection ()

- (void)_loadDatabaseParameters;
- (void)_createConnectionParameters;
- (void)_pollConnection:(NSNumber *)isReset;

// libpq callback
static void _PGPostgresConnectionNoticeProcessor(void *arg, const char *message);

@end

@implementation PGPostgresConnection

@synthesize port = _port;
@synthesize host = _host;
@synthesize user = _user;
@synthesize database = _database;
@synthesize password = _password;
@synthesize useSocket = _useSocket;
@synthesize socketPath = _socketPath;
@synthesize delegate = _delegate;
@synthesize timeout = _timeout;
@synthesize useKeepAlive = _useKeepAlive;
@synthesize keepAliveInterval = _keepAliveInterval;
@synthesize lastQueryWasCancelled = _lastQueryWasCancelled;
@synthesize lastError = _lastError;
@synthesize encoding = _encoding;
@synthesize connectionError = _connectionError;
@synthesize stringEncoding = _stringEncoding;
@synthesize parameters = _parameters;
@synthesize applicationName = _applicationName;
@synthesize lastQueryAffectedRowCount = _lastQueryAffectedRowCount;

#pragma mark -
#pragma mark Initialisation

- (id)init 
{
	return [self initWithDelegate:nil];
}

/**
 * Initialise a new connection with the supplied delegate.
 *
 * @param delegate The delegate this connection should use.
 *
 * @return The new connection instance.
 */
- (id)initWithDelegate:(NSObject <PGPostgresConnectionDelegate> *)delegate
{
	if ((self = [super init])) {
		
		_delegate = delegate;
		
		_port = PGPostgresConnectionDefaultServerPort;
		_timeout = PGPostgresConnectionDefaultTimeout;
		
		_useKeepAlive = YES;
		_keepAliveInterval = PGPostgresConnectionDefaultKeepAlive;
		
		_lastQueryAffectedRowCount = 0;
		
		_lastError = nil;
		_connection = nil;
		_connectionError = nil;
		_lastQueryWasCancelled = NO;
		
		_stringEncoding = PGPostgresConnectionDefaultStringEncoding;
		_encoding = [NSString stringWithString:PGPostgresConnectionDefaultEncoding];
		
		_delegateSupportsWillExecute = [_delegate respondsToSelector:@selector(connection:willExecute:withValues:)];
		
		_typeMap = [[NSMutableDictionary alloc] init];
		
		[self registerTypeHandlers];
	}
	
	return self;
}

#pragma mark -
#pragma mark Accessors

/**
 * Get the underlying connection associated with this wrapper.
 *
 * @return The PGConn instance.
 */
- (PGconn *)postgresConnection
{
	return _connection;
}

#pragma mark -
#pragma mark Connection Handling

/**
 * Does this connection have an underlying connection established with the server.
 *
 * @return A BOOL indicating the result of the query.
 */
- (BOOL)isConnected 
{
	if (!_connection) return NO;
	
	return PQstatus(_connection) == CONNECTION_OK;
}

/**
 * Attempts to disconnect the underlying connection with the server.
 */
- (void)disconnect 
{
	if (!_connection) return;
	
	[self cancelCurrentQuery:nil];
	
	PQfinish(_connection);
	
	_connection = nil;
	
	if (_delegate && [_delegate respondsToSelector:@selector(connectionDisconnected:)]) {
		[_delegate connectionDisconnected:self];
	}
}

/**
 * Initiates the underlying connection to the server asynchronously.
 *
 * Note, that if no user, host or database is set when connect is called, then libpq's defaults are used.
 * For no host, this means a socket connection to /tmp is attempted.
 *
 * @return A BOOL indicating the success of requesting the connection. Note, that this does not indicate
 *         that a successful connection has been made, only that it has successfullly been requested.
 */
- (BOOL)connect 
{
	if ([self isConnected]) return YES;
	
	[self _createConnectionParameters];
	
	// Perform the connection
    
	_connection = PQconnectStartParams(_connectionParamNames, _connectionParamValues, 0);
    
	if (!_connection || PQstatus(_connection) == CONNECTION_BAD) {
		
        if (_connectionErrorType) [_connectionErrorType release];
        if (_connectionError) [_connectionError release];
        
        _connectionError = [[NSString alloc] initWithUTF8String:PQerrorMessage(_connection)];
        _connectionErrorType = @"CONNECTION_BAD";
        
        if (_delegate && [_delegate respondsToSelector:@selector(connectionFailed:)]) {
            [_delegate performSelectorOnMainThread:@selector(connectionFailed:) withObject:self waitUntilDone:NO];
        }
		
		PQfinish(_connection);
		
		_connection = nil;
		
		return NO;
	}
	
	[self performSelectorInBackground:@selector(_pollConnection:) withObject:nil];
	
	return YES;
}

/**
 * Attempts the reset the underlying connection.
 *
 * @note A return value of NO means that the connection is not currently 
 *       connected or the request to reset it failed. YES means the reset request was successful, 
 *       not that the connection re-establishment has succeeded. Wait for the
 *       delegate connection reset method to be called and check -isConnected.
 *
 * @return A BOOL indicating the success of the call.
 */
- (BOOL)reset 
{
	if (![self isConnected]) return NO;
	
	if (!PQresetStart(_connection)) return NO;
	
	[self performSelectorInBackground:@selector(_pollConnection:) withObject:[NSNumber numberWithBool:YES]];
	
	return YES;
}

/**
 * Returns the PostgreSQL client library (libpq) version being used.
 *
 * @return The library version (e.g. version 9.1 is 90100).
 */
- (NSUInteger)clientVersion
{
	return PQlibVersion();
}

/**
 * Returns the version of the server we're connected to.
 *
 * @return The server version (e.g. version 9.1 is 90100). -1 is returned if there's no connection.
 */
- (NSUInteger)serverVersion
{
	if (![self isConnected]) return -1;
	
	return PQserverVersion(_connection);
}

/**
 * Returns the ID of the process handling this connection on the remote host.
 *
 * @return The process ID or -1 if no connection is available.
 */
- (NSUInteger)serverProcessId
{
	if (![self isConnected]) return -1;
	
	return PQbackendPID(_connection);
}

/**
 * Attempts to cancel the query currently executing on this connection.
 *
 * @param error Populated if query was unabled to be cancelled.
 *
 * @return A BOOL indicating the success of the request
 */
- (BOOL)cancelCurrentQuery:(NSError **)error
{
	if (![self isConnected]) return NO;
	
	PGcancel *cancel = PQgetCancel(_connection);
	
	if (!cancel) return NO;
	
	char errorBuf[256]; 
	
	int result = PQcancel(cancel, errorBuf, 256);
	
	PQfreeCancel(cancel);
	
	if (!result) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:PGPostgresConnectionErrorDomain 
										 code:0 
									 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithUTF8String:errorBuf] forKey:NSLocalizedDescriptionKey]];
		}

		return NO;
	}
	
	_lastQueryWasCancelled = YES;
	
	return YES;
}

#pragma mark -
#pragma mark Private API

/**
 * Polls the connection that was previously requested via -connect and waits for meaninful status.
 *
 * @note This method should be called on a background thread as it will block waiting for the connection.
 */
- (void)_pollConnection:(NSNumber *)isReset
{
    NSLog(@"Polling connection");
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	BOOL reset = isReset && [isReset boolValue];
	
	int sock = PQsocket(_connection);
	
	if (sock == -1) {
        NSLog(@"Polling status: could not obtain socket");
		[pool release];
		return;
	}
	
	struct pollfd fdinfo[1];
	
	fdinfo[0].fd = sock;
	fdinfo[0].events = POLLIN|POLLOUT;
	
	PostgresPollingStatusType status;
    
	do
	{
		status = reset ? PQresetPoll(_connection) : PQconnectPoll(_connection);
		
		if (status == PGRES_POLLING_READING || status == PGRES_POLLING_WRITING) {			
			if (poll(fdinfo, 1, -1) < 0) break;
		}
        
        NSLog(@"Polling ...");
	}
	while (status != PGRES_POLLING_OK && status != PGRES_POLLING_FAILED);
	
    // http://www.linuxzone.cz/files/p2/example4.c
    if (status == PGRES_POLLING_FAILED)
    {
        NSLog(@"Poll failed");
        
        if (_connectionError) [_connectionError release];
        if (_connectionErrorType) [_connectionErrorType release];
        
        _connectionError = [[NSString alloc] initWithUTF8String:PQerrorMessage(_connection)];
        _connectionErrorType = @"CONNECTION_POLL_FAILED";
        
                
        if (_delegate && [_delegate respondsToSelector:@selector(connectionFailed:)]) {
            [_delegate performSelectorOnMainThread:@selector(connectionFailed:) withObject:self waitUntilDone:NO];
        }
        
        return;
    }
    
    if (status == PGRES_POLLING_OK)
    {
        if ([self isConnected]) {
            NSLog(@"Poll status successful, connected");
        } else {
            NSLog(@"Poll status successful, not connected");
        }
    }
    
	if (status == PGRES_POLLING_OK && [self isConnected]) {
        NSLog(@"Poll successful!");
		// Increase error verbosity
		PQsetErrorVerbosity(_connection, PQERRORS_VERBOSE);
		
		// Set notice processor
		PQsetNoticeProcessor(_connection, _PGPostgresConnectionNoticeProcessor, self);
		
		// Register or clear type extensions
		NSInteger success = reset ? PQclearTypes(_connection) : PQinitTypes(_connection);
		
		if (!success) {
			NSLog(@"PostgresKit: Error: Failed to initialise or clear type extensions. Connection might return unexpected results!");
		}
		
		[self _loadDatabaseParameters];
		
		if (reset) {
			if (_delegate && [_delegate respondsToSelector:@selector(connectionReset:)]) {
				[_delegate performSelectorOnMainThread:@selector(connectionReset:) withObject:self waitUntilDone:NO];
			}
		}
		else {
			if (_delegate && [_delegate respondsToSelector:@selector(connectionEstablished:)]) {
				[_delegate performSelectorOnMainThread:@selector(connectionEstablished:) withObject:self waitUntilDone:NO];
			}
		}
	}
		
	[pool release];
}

/**
 * Loads the database parameters.
 */
- (void)_loadDatabaseParameters
{
	if (_parameters) [_parameters release];
	
	_parameters = [[PGPostgresConnectionParameters alloc] initWithConnection:self];
	
	BOOL success = [_parameters loadParameters];
	
	if (!success) NSLog(@"PostgresKit: Warning: Failed to load database parameters.");
}

/**
 * libpq notice processor function. Simply passes the message onto the connection delegate.
 *
 * @param arg     The calling connection.
 * @param message The message that was sent.
 */
static void _PGPostgresConnectionNoticeProcessor(void *arg, const char *message) 
{
	PGPostgresConnection *connection = (PGPostgresConnection *)arg;
	
	if ([connection isKindOfClass:[PGPostgresConnection class]]) {
		
		if ([connection delegate] && [[connection delegate] respondsToSelector:@selector(connection:notice:)]) {
			[[connection delegate] connection:connection notice:[NSString stringWithUTF8String:message]];
		}
	}
}

/**
 * Creates the parameter arrays required to establish a connection.
 */
- (void)_createConnectionParameters
{
	BOOL hasUser = NO;
	BOOL hasHost = NO;
	BOOL hasPassword = NO;
	BOOL hasDatabase = NO;
	
    if (_connectionParamNames) free(_connectionParamNames);
    if (_connectionParamValues) free(_connectionParamValues);
	
	int paramCount = 5;
	
	if (_user && [_user length]) paramCount++, hasUser = YES;
	if (_host && [_host length]) paramCount++, hasHost = YES;
	if (_password && [_password length]) paramCount++, hasPassword = YES;
	if (_database && [_database length]) paramCount++, hasDatabase = YES;
	
	_connectionParamNames = malloc((paramCount + 1) * sizeof(*_connectionParamNames));
	_connectionParamValues = malloc((paramCount + 1)* sizeof(*_connectionParamValues));
	
	_connectionParamNames[0] = PGPostgresApplicationParam;
	_connectionParamValues[0] = !_applicationName ? [_applicationName UTF8String] : PGPostgresKitApplicationName;
	
	_connectionParamNames[1] = PGPostgresPortParam;
	_connectionParamValues[1] = [[[NSNumber numberWithUnsignedInteger:_port] stringValue] UTF8String];
	
	_connectionParamNames[2] = PGPostgresClientEncodingParam;
	_connectionParamValues[2] = [_encoding UTF8String];
	
	_connectionParamNames[3] = PGPostgresKeepAliveParam;
	_connectionParamValues[3] = _useKeepAlive ? "1" : "0";
	
	_connectionParamNames[4] = PGPostgresKeepAliveIntervalParam;
	_connectionParamValues[4] = [[[NSNumber numberWithUnsignedInteger:_keepAliveInterval] stringValue] UTF8String];
	
	NSUInteger i = 5;
	
	if (hasUser) {
		_connectionParamNames[i] = PGPostgresUserParam;
		_connectionParamValues[i] = [_user UTF8String];
		
		i++;
	}
	
	if (hasHost) {
		_connectionParamNames[i] = PGPostgresHostParam;
		_connectionParamValues[i] = [_host UTF8String];
		
		i++;
	}
	
	if (hasPassword) {
		_connectionParamNames[i] = PGPostgresPasswordParam;
		_connectionParamValues[i] = [_password UTF8String];
		
		i++;
	}	
	
	if (hasDatabase) {
		_connectionParamNames[i] = PGPostgresDatabaseParam;
		_connectionParamValues[i] = [_database UTF8String];
		
		i++;
	}
	
	_connectionParamNames[i] = NULL;
	_connectionParamValues[i] = NULL;
}

#pragma mark -

- (void)dealloc 
{
	[_typeMap release];
	
	[self disconnect];
	
	[self setHost:nil];
	[self setUser:nil];
	[self setDatabase:nil];
	
	if (_connectionParamNames) free(_connectionParamNames);
	if (_connectionParamValues) free(_connectionParamValues);
	
	if (_lastError) [_lastError release], _lastError = nil;
	if (_parameters) [_parameters release], _parameters = nil;
	if (_connectionError) [_connectionError release], _connectionError = nil;
	if (_applicationName) [_applicationName release], _applicationName = nil;
	
	[super dealloc];
}

#pragma mark Acochambração

- (NSInteger)lastErrorID
{
    return 666;
}

/**
 * Returns YES if the user chose to disconnect at the last "connection failure"
 * prompt, NO otherwise.  This can be used to alter behaviour in response to state
 * changes.
 */
- (BOOL)userTriggeredDisconnect
{
    return NO;
}

/**
 * Checks whether the connection to the server is still active.  This verifies
 * the connection using a ping, and if the connection is found to be down attempts
 * to quickly restore it, including the previous state.
 */
// TODO: do proper check connection
- (BOOL)checkConnection
{
    return YES;
//    // If the connection is not seen as active, don't proceed
//    if (state != SPMySQLConnected) return NO;
//    
//    // Similarly, if the connection is currently locked, that indicates it's in use.  This
//    // could be because queries are actively being run, or that a ping is running.
//    if ([connectionLock condition] == SPMySQLConnectionBusy) {
//        
//        // If a ping thread is not active queries are being performed - return success.
//        if (!keepAlivePingThreadActive) return YES;
//        
//        // If a ping thread is active, wait for it to complete before checking the connection
//        while (keepAlivePingThreadActive) {
//            usleep(10000);
//        }
//    }
//    
//    // Confirm whether the connection is still responding by using a ping
//    BOOL connectionVerified = [self _pingConnectionUsingLoopDelay:400];
//    
//    // If the connection didn't respond, trigger a reconnect.  This will automatically
//    // attempt to reconnect once, and if that fails will ask the user how to proceed - whether
//    // to keep reconnecting, or whether to disconnect.
//    if (!connectionVerified) {
//        connectionVerified = [self _reconnectAllowingRetries:YES];
//    }
//    
//    // Update the connection tracking use variable if the connection was confirmed,
//    // as at least a mysql_ping will have been used.
//    if (connectionVerified) {
//        lastConnectionUsedTime = mach_absolute_time();
//    }
//    
//    return connectionVerified;
}


@end
