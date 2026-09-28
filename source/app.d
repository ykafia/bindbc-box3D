import bindbc.box3d;
import bindbc.loader.sharedlib : LoadMsg;
import loader = bindbc.loader.sharedlib;
import std.stdio : stderr, writeln;
import std.string : fromStringz, toStringz;

void main(string[] args)
{
	LoadMsg loadResult;
	if (args.length > 1)
		loadResult = loadBox3D(args[1].toStringz);
	else
		loadResult = loadBox3D();

	if (loadResult != LoadMsg.success)
	{
		stderr.writeln("Could not load Box3D (loader status: ", loadResult, ").");
		foreach (error; loader.errors())
			stderr.writeln(fromStringz(error.error), ": ", fromStringz(error.message));
		stderr.writeln("Pass the Box3D shared-library path or add it to the OS loader search path.");
		return;
	}

	auto versionInfo = b3GetVersion();
	writeln("Box3D ", versionInfo.major, ".", versionInfo.minor, ".", versionInfo.revision);
	runStaticBodySimulation();
	runKinematicVelocityExample();
	runGravityCollisionExample();
	unloadBox3D();
}

void runStaticBodySimulation()
{
	auto worldDefinition = b3DefaultWorldDef();
	auto world = b3CreateWorld(&worldDefinition);
	auto shapeDefinition = b3DefaultShapeDef();

	auto boxBodyDefinition = b3DefaultBodyDef();
	boxBodyDefinition.position.y = 1.0f;
	auto boxBody = b3CreateBody(world, &boxBodyDefinition);
	auto box = b3MakeBoxHull(1.0f, 1.0f, 1.0f);
	b3CreateHullShape(boxBody, &shapeDefinition, &box.base);

	auto sphereBodyDefinition = b3DefaultBodyDef();
	sphereBodyDefinition.position.y = 3.0f;
	auto sphereBody = b3CreateBody(world, &sphereBodyDefinition);
	auto sphereDefinition = b3Sphere(b3Vec3.init, 0.5f);
	b3CreateSphereShape(sphereBody, &shapeDefinition, &sphereDefinition);

	foreach (_; 0 .. 120)
		b3World_Step(world, 1.0f / 60.0f, 4);

	auto counters = b3World_GetCounters(world);
	writeln("Static-body simulation: ", counters.bodyCount, " bodies after 2 seconds.");
	b3DestroyWorld(world);
}

void runKinematicVelocityExample()
{
	auto worldDefinition = b3DefaultWorldDef();
	auto world = b3CreateWorld(&worldDefinition);
	auto bodyDefinition = b3DefaultBodyDef();
	bodyDefinition.type = b3_kinematicBody;
	bodyDefinition.position.y = 2.0f;
	auto body = b3CreateBody(world, &bodyDefinition);
	auto shapeDefinition = b3DefaultShapeDef();
	auto sphereDefinition = b3Sphere(b3Vec3.init, 0.5f);
	b3CreateSphereShape(body, &shapeDefinition, &sphereDefinition);
	b3Body_SetLinearVelocity(body, b3Vec3(1.0f, 0.0f, 0.0f));
	auto requestedVelocity = b3Body_GetLinearVelocity(body);
	writeln("Requested kinematic velocity: (", requestedVelocity.x, ", ", requestedVelocity.y, ", ",
		requestedVelocity.z, ")");

	foreach (_; 0 .. 60)
	{
		b3Body_SetLinearVelocity(body, b3Vec3(1.0f, 0.0f, 0.0f));
		b3World_Step(world, 1.0f / 60.0f, 4);
	}

	auto velocity = b3Body_GetLinearVelocity(body);
	auto position = b3Body_GetPosition(body);
	writeln("Reported velocity after stepping: (", velocity.x, ", ", velocity.y, ", ", velocity.z, ")");
	writeln("Position after 1 second: (", position.x, ", ", position.y, ", ", position.z, ")");
	b3DestroyWorld(world);
}

void runGravityCollisionExample()
{
	auto worldDefinition = b3DefaultWorldDef();
	auto world = b3CreateWorld(&worldDefinition);

	auto groundBodyDefinition = b3DefaultBodyDef();
	groundBodyDefinition.position.y = -0.5f;
	auto groundBody = b3CreateBody(world, &groundBodyDefinition);
	auto groundShapeDefinition = b3DefaultShapeDef();
	auto groundBox = b3MakeBoxHull(10.0f, 0.5f, 10.0f);
	b3CreateHullShape(groundBody, &groundShapeDefinition, &groundBox.base);

	auto sphereBodyDefinition = b3DefaultBodyDef();
	sphereBodyDefinition.type = b3_kinematicBody;
	sphereBodyDefinition.position.y = 5.0f;
	auto sphereBody = b3CreateBody(world, &sphereBodyDefinition);
	auto sphereShapeDefinition = b3DefaultShapeDef();
	sphereShapeDefinition.enableContactEvents = true;
	auto sphere = b3Sphere(b3Vec3.init, 0.5f);
	b3CreateSphereShape(sphereBody, &sphereShapeDefinition, &sphere);
	auto velocity = b3Vec3.init;
	bool contactDetected;
	int contactBeginCount;
	enum timeStep = 1.0f / 60.0f;

	foreach (_; 0 .. 180)
	{
		velocity.y += worldDefinition.gravity.y * timeStep;
		b3Body_SetLinearVelocity(sphereBody, velocity);
		b3World_Step(world, timeStep, 4);
		auto events = b3World_GetContactEvents(world);
		contactBeginCount += events.beginCount;
		if (events.beginCount > 0)
		{
			contactDetected = true;
			break;
		}
	}

	auto position = b3Body_GetPosition(sphereBody);
	writeln("Gravity/contact-event test: contact=", contactDetected, ", begin events=", contactBeginCount,
		", sphere height=", position.y, " (gravity integrated in D).");
	b3DestroyWorld(world);
}
