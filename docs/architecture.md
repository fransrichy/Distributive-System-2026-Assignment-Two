# Distributed Food Delivery Platform Architecture

## Overview

The Distributed Food Delivery Platform is designed using a microservices
architecture. Each major business function is implemented as an independent
service.

## Services

The platform consists of the following services:

1. Customer Service
2. Restaurant Service
3. Order Service
4. Payment Service
5. Delivery Service
6. Notification Service
7. Admin Service

## Communication

Kafka is used for asynchronous communication between services.

Example topics include:

- orders.created
- payments.completed
- delivery.assigned
- delivery.completed

## Order Lifecycle

Orders follow the following lifecycle:

CREATED → CONFIRMED → PREPARING → READY → OUT_FOR_DELIVERY → DELIVERED

An order can also be cancelled where appropriate.

## Event Flow

Customer places an order.

Customer Service / API
        |
        v
Order Service
        |
        | orders.created
        v
      Kafka
       / \
      /   \
     v     v
Restaurant Payment
Service    Service
             |
             | payments.completed
             v
           Kafka
             |
             v
        Order Service
             |
             v
        Order Confirmed

After the restaurant prepares the order:

Restaurant Service
        |
        | order.ready
        v
      Kafka
        |
        v
Delivery Service
        |
        | delivery.assigned
        v
      Driver

After delivery:

Delivery Service
        |
        | delivery.completed
        v
      Kafka
        |
        v
Order Service
        |
        v
     DELIVERED

## Persistence

Each service is responsible for managing its own required data. MongoDB or
SQL can be used for persistent storage depending on the service requirements.

## Containerisation

Docker containers will be used to isolate the individual services and their
dependencies. Docker Compose will be used to orchestrate the complete local
development environment.