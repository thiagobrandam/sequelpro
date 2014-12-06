//
//  PGPostgresConnection+Querying_and_Preparation.m
//  PostgresKit
//
//  Created by thiago on 12/6/14.
//
//

#import "PGPostgresConnection+Querying_and_Preparation.h"

@implementation PGPostgresConnection (Querying_and_Preparation)


/**
 * If the last query (or connection) triggered an error, returns the error
 * message as a string; if the last query did not error, nil is returned.
 */
- (NSString *)lastErrorMessage
{
    return _connectionError;
}

@end
